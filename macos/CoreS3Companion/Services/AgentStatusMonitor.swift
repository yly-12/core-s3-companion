import Foundation

protocol AgentStatusMonitoring: AnyObject {
    var onSnapshots: (([AgentSnapshot]) -> Void)? { get set }
    var selectedSource: AgentSource { get set }
    var defaultTool: DefaultAgentTool { get set }
    func start()
    func stop()
    func refresh()
}

final class AgentStatusMonitor: AgentStatusMonitoring {
    private static let claudeUsageRefreshInterval: TimeInterval = 5 * 60

    var onSnapshots: (([AgentSnapshot]) -> Void)?
    var selectedSource: AgentSource = .automatic
    var defaultTool: DefaultAgentTool = .claude

    private let stateDirectoryURL: URL
    private let codexSessionsURL: URL
    private let claudeSessionsURL: URL
    private let claudeProjectsURL: URL
    private let claudeConfigurationURL: URL
    private let codexSessionIndexURL: URL
    private let fileManager: FileManager
    private let claudeUsageRefresher: ClaudeUsageRefreshing?
    private let currentDate: () -> Date
    private var timer: Timer?
    private var codexRolloutCache: [URL: CodexRolloutReader.CacheEntry] = [:]
    private var cachedCodexRollouts: [CodexRolloutReader.Snapshot] = []
    private var lastCodexScanAt = Date.distantPast
    private var claudeTranscriptCache: [URL: ClaudeTranscriptCacheEntry] = [:]
    private var lastClaudeUsageRefreshAttemptAt = Date.distantPast
    private var claudeUsageRefreshInFlight = false
    private var refreshedClaudeUsage: AgentUsage?

    init(
        stateDirectoryURL: URL = AgentStatusMonitor.defaultStateDirectoryURL,
        codexSessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        claudeSessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true),
        claudeProjectsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        claudeConfigurationURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json"),
        codexSessionIndexURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl"),
        fileManager: FileManager = .default,
        claudeUsageRefresher: ClaudeUsageRefreshing? = nil,
        currentDate: @escaping () -> Date = Date.init
    ) {
        self.stateDirectoryURL = stateDirectoryURL
        self.codexSessionsURL = codexSessionsURL
        self.claudeSessionsURL = claudeSessionsURL
        self.claudeProjectsURL = claudeProjectsURL
        self.claudeConfigurationURL = claudeConfigurationURL
        self.codexSessionIndexURL = codexSessionIndexURL
        self.fileManager = fileManager
        self.claudeUsageRefresher = claudeUsageRefresher
        self.currentDate = currentDate
    }

    static var defaultApplicationSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoreS3Companion", isDirectory: true)
    }

    static var defaultStateDirectoryURL: URL {
        defaultApplicationSupportURL.appendingPathComponent("state", isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        refreshClaudeUsageIfNeeded(force: true)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.refreshClaudeUsageIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let claudeUsage = loadClaudeUsage()
        let claudeRecords = loadHookRecords(for: .claude)
        let claudeTranscriptUsage = loadClaudeTranscriptUsage(
            for: Set(claudeRecords.map(\.sessionID))
        )
        let claudeSnapshots = snapshots(
            from: claudeRecords,
            fallbackUsage: claudeUsage,
            sessionTitles: loadClaudeSessionTitles(),
            transcriptUsage: claudeTranscriptUsage
        )

        let codexHooks = loadHookRecords(for: .codex)
        let codexRollouts = loadCodexRollouts()
        let codexSnapshots = mergeCodex(
            hooks: codexHooks,
            rollouts: codexRollouts,
            sessionTitles: loadCodexSessionTitles()
        )

        let candidates: [AgentSnapshot]
        switch selectedSource {
        case .claude:
            candidates = claudeSnapshots
        case .codex:
            candidates = codexSnapshots
        case .automatic:
            candidates = claudeSnapshots + codexSnapshots
        }

        let active = candidates
            .filter(isActive)
            .sorted(by: snapshotPrecedes)
        if !active.isEmpty {
            onSnapshots?(active)
            return
        }

        let fallbackCandidates: [AgentSnapshot]
        if selectedSource == .automatic {
            let preferred = candidates.filter { $0.source == defaultTool.source }
            fallbackCandidates = preferred.isEmpty ? candidates : preferred
        } else {
            fallbackCandidates = candidates
        }

        if var fallback = fallbackCandidates.max(by: { snapshotDate($0) < snapshotDate($1) }) {
            fallback.state = .idle
            onSnapshots?([fallback])
        } else {
            var idle = AgentSnapshot.idle
            idle.source = selectedSource == .automatic ? defaultTool.source : selectedSource
            onSnapshots?([idle])
        }
    }

    private func snapshots(
        from records: [StatusRecord],
        fallbackUsage: AgentUsage?,
        sessionTitles: [String: String],
        transcriptUsage: [String: ClaudeTranscriptUsage]
    ) -> [AgentSnapshot] {
        records.map { record in
            let transcript = transcriptUsage[record.sessionID]
            return AgentSnapshot(
                sessionID: record.sessionID,
                source: record.source,
                state: record.state,
                title: nonEmpty(sessionTitles[record.sessionID])
                    ?? nonEmpty(transcript?.aiTitle)
                    ?? nonEmpty(record.title)
                    ?? "NO ACTIVE SESSION",
                modelName: nonEmpty(record.modelName) ?? nonEmpty(transcript?.modelName),
                effort: nonEmpty(record.effort),
                fiveHourRemaining: fallbackUsage?.fiveHourRemaining,
                weeklyRemaining: fallbackUsage?.weeklyRemaining,
                contextUsed: record.contextUsed ?? transcript?.contextUsed ?? fallbackUsage?.contextUsed,
                fiveHourResetsAt: fallbackUsage?.fiveHourResetsAt,
                weeklyResetsAt: fallbackUsage?.weeklyResetsAt,
                updatedAt: record.updatedAt ?? fallbackUsage?.updatedAt
            )
        }
    }

    private func mergeCodex(
        hooks: [StatusRecord],
        rollouts: [CodexRolloutReader.Snapshot],
        sessionTitles: [String: String]
    ) -> [AgentSnapshot] {
        let globalUsage = rollouts.compactMap(\.usage).max(by: {
            ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast)
        })
        var rolloutByID: [String: CodexRolloutReader.Snapshot] = [:]
        for rollout in rollouts where rolloutByID[rollout.record.sessionID] == nil {
            rolloutByID[rollout.record.sessionID] = rollout
        }
        var results: [AgentSnapshot] = []

        for hook in hooks {
            let rollout = rolloutByID.removeValue(forKey: hook.sessionID)
            let rolloutRecord = rollout?.record
            let stateRecord = newest(hook, rolloutRecord)
            let usage = rollout?.usage ?? globalUsage
            results.append(AgentSnapshot(
                sessionID: hook.sessionID,
                source: .codex,
                state: stateRecord.state,
                title: nonEmpty(sessionTitles[hook.sessionID])
                    ?? nonEmpty(hook.title)
                    ?? nonEmpty(rolloutRecord?.title)
                    ?? "CODEX SESSION",
                modelName: nonEmpty(rolloutRecord?.modelName) ?? nonEmpty(hook.modelName),
                effort: nonEmpty(rolloutRecord?.effort) ?? nonEmpty(hook.effort),
                fiveHourRemaining: usage?.fiveHourRemaining,
                weeklyRemaining: usage?.weeklyRemaining,
                contextUsed: rollout?.usage?.contextUsed ?? hook.contextUsed,
                fiveHourResetsAt: usage?.fiveHourResetsAt,
                weeklyResetsAt: usage?.weeklyResetsAt,
                updatedAt: stateRecord.updatedAt
            ))
        }

        for rollout in rolloutByID.values {
            let usage = rollout.usage ?? globalUsage
            results.append(AgentSnapshot(
                sessionID: rollout.record.sessionID,
                source: .codex,
                state: rollout.record.state,
                title: nonEmpty(sessionTitles[rollout.record.sessionID])
                    ?? nonEmpty(rollout.record.title)
                    ?? "CODEX SESSION",
                modelName: nonEmpty(rollout.record.modelName),
                effort: nonEmpty(rollout.record.effort),
                fiveHourRemaining: usage?.fiveHourRemaining,
                weeklyRemaining: usage?.weeklyRemaining,
                contextUsed: rollout.usage?.contextUsed,
                fiveHourResetsAt: usage?.fiveHourResetsAt,
                weeklyResetsAt: usage?.weeklyResetsAt,
                updatedAt: rollout.record.updatedAt
            ))
        }
        return results
    }

    private func loadClaudeSessionTitles() -> [String: String] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: claudeSessionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var titles: [String: String] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let metadata = try? JSONDecoder().decode(ClaudeSessionMetadata.self, from: data),
                  metadata.nameSource?.caseInsensitiveCompare("derived") != .orderedSame,
                  let title = nonEmpty(metadata.name) else {
                continue
            }
            titles[metadata.sessionID] = title
        }
        return titles
    }

    private func loadCodexSessionTitles() -> [String: String] {
        guard let contents = try? String(contentsOf: codexSessionIndexURL, encoding: .utf8) else {
            return [:]
        }

        var titles: [String: String] = [:]
        contents.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode(CodexSessionMetadata.self, from: data),
                  let title = self.nonEmpty(metadata.threadName) else {
                return
            }
            titles[metadata.id] = title
        }
        return titles
    }

    private func loadHookRecords(for source: AgentSource) -> [StatusRecord] {
        var urls: [URL] = []
        if let contents = try? fileManager.contentsOfDirectory(
            at: stateDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: contents.filter {
                $0.lastPathComponent.hasPrefix("\(source.rawValue)-session-") && $0.pathExtension == "json"
            })
        }
        let legacyURL = stateDirectoryURL.appendingPathComponent("\(source.rawValue)-state.json")
        if fileManager.fileExists(atPath: legacyURL.path) { urls.append(legacyURL) }

        var recordsByID: [String: StatusRecord] = [:]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(HookStatePayload.self, from: data),
                  let state = AgentRunState(hookValue: payload.state) else {
                continue
            }
            let fallbackID = url.deletingPathExtension().lastPathComponent
            let record = StatusRecord(
                sessionID: nonEmpty(payload.sessionID) ?? fallbackID,
                source: source,
                state: state,
                title: payload.title ?? "",
                modelName: payload.modelName,
                effort: payload.effort,
                contextUsed: percentage(payload.contextUsed),
                updatedAt: payload.updatedAt.map(Date.init(timeIntervalSince1970:))
            )
            if let existing = recordsByID[record.sessionID],
               (existing.updatedAt ?? .distantPast) >= (record.updatedAt ?? .distantPast) {
                continue
            }
            recordsByID[record.sessionID] = record
        }
        return Array(recordsByID.values)
    }

    private func loadClaudeUsage() -> AgentUsage? {
        let persistedSources = [loadClaudeStatusLineUsage(), loadClaudeCachedUsage()]
            .compactMap { $0 }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        let commandUsage: AgentUsage?
        if let usage = refreshedClaudeUsage,
           currentDate().timeIntervalSince(usage.updatedAt ?? .distantPast) <=
           Self.claudeUsageRefreshInterval * 2 {
            commandUsage = usage
        } else {
            commandUsage = nil
        }
        let sources: [AgentUsage] = commandUsage.map { [$0] + persistedSources }
            ?? persistedSources
        guard !sources.isEmpty else { return nil }

        func newestValue(_ value: (AgentUsage) -> UInt8?) -> UInt8? {
            for source in sources {
                if let result = value(source) { return result }
            }
            return nil
        }

        func newestDate(_ value: (AgentUsage) -> Date?) -> Date? {
            for source in sources {
                if let result = value(source) { return result }
            }
            return nil
        }

        return AgentUsage(
            fiveHourRemaining: newestValue(\.fiveHourRemaining),
            weeklyRemaining: newestValue(\.weeklyRemaining),
            contextUsed: newestValue(\.contextUsed),
            fiveHourResetsAt: newestDate(\.fiveHourResetsAt),
            weeklyResetsAt: newestDate(\.weeklyResetsAt),
            updatedAt: sources.compactMap(\.updatedAt).max()
        )
    }

    private func refreshClaudeUsageIfNeeded(force: Bool = false) {
        guard let claudeUsageRefresher,
              selectedSource != .codex,
              !claudeUsageRefreshInFlight else {
            return
        }
        let now = currentDate()
        guard force || now.timeIntervalSince(lastClaudeUsageRefreshAttemptAt) >=
            Self.claudeUsageRefreshInterval else {
            return
        }
        lastClaudeUsageRefreshAttemptAt = now
        claudeUsageRefreshInFlight = true
        claudeUsageRefresher.refresh(configurationURL: claudeConfigurationURL) { [weak self] outcome in
            guard let self else { return }
            self.claudeUsageRefreshInFlight = false
            switch outcome {
            case .cacheAdvanced:
                self.refreshedClaudeUsage = nil
                print("[ClaudeUsage] /usage refreshed ~/.claude.json")
            case let .commandOutput(snapshot):
                self.refreshedClaudeUsage = AgentUsage(
                    fiveHourRemaining: snapshot.fiveHourRemaining,
                    weeklyRemaining: snapshot.weeklyRemaining,
                    contextUsed: nil,
                    updatedAt: snapshot.updatedAt
                )
                print("[ClaudeUsage] /usage returned fresh data without cache persistence")
            case nil:
                print("[ClaudeUsage] /usage refresh failed validation")
            }
            self.refresh()
        }
    }

    private func loadClaudeStatusLineUsage() -> AgentUsage? {
        let url = stateDirectoryURL.appendingPathComponent("claude-usage.json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(ClaudeUsagePayload.self, from: data) else {
            return nil
        }
        return AgentUsage(
            fiveHourRemaining: remaining(fromUsed: payload.fiveHourUsed),
            weeklyRemaining: remaining(fromUsed: payload.weeklyUsed),
            contextUsed: percentage(payload.contextUsed),
            fiveHourResetsAt: payload.fiveHourResetsAt.map(Date.init(timeIntervalSince1970:)),
            weeklyResetsAt: payload.weeklyResetsAt.map(Date.init(timeIntervalSince1970:)),
            updatedAt: payload.updatedAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func loadClaudeCachedUsage() -> AgentUsage? {
        guard let data = try? Data(contentsOf: claudeConfigurationURL),
              let payload = try? JSONDecoder().decode(ClaudeConfigurationPayload.self, from: data),
              let cache = payload.cachedUsageUtilization else {
            return nil
        }
        return AgentUsage(
            fiveHourRemaining: remaining(fromUsed: cache.utilization?.fiveHour?.utilization),
            weeklyRemaining: remaining(fromUsed: cache.utilization?.sevenDay?.utilization),
            contextUsed: nil,
            fiveHourResetsAt: cache.utilization?.fiveHour?.resetsAt,
            weeklyResetsAt: cache.utilization?.sevenDay?.resetsAt,
            updatedAt: cache.fetchedAtMs.map { Date(timeIntervalSince1970: $0 / 1_000) }
        )
    }

    private func loadClaudeTranscriptUsage(
        for sessionIDs: Set<String>
    ) -> [String: ClaudeTranscriptUsage] {
        guard !sessionIDs.isEmpty,
              let enumerator = fileManager.enumerator(
                  at: claudeProjectsURL,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return [:]
        }

        var result: [String: ClaudeTranscriptUsage] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let sessionID = url.deletingPathExtension().lastPathComponent
            guard sessionIDs.contains(sessionID),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .fileSizeKey]
                  ) else {
                continue
            }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let fileSize = values.fileSize ?? 0
            let entry: ClaudeTranscriptCacheEntry
            if let cached = claudeTranscriptCache[url],
               cached.modifiedAt == modifiedAt,
               cached.fileSize == fileSize {
                entry = cached
            } else {
                entry = ClaudeTranscriptCacheEntry(
                    modifiedAt: modifiedAt,
                    fileSize: fileSize,
                    usage: ClaudeTranscriptReader.read(from: url)
                )
                claudeTranscriptCache[url] = entry
            }
            if let usage = entry.usage {
                result[sessionID] = usage
            }
        }
        return result
    }

    private func loadCodexRollouts() -> [CodexRolloutReader.Snapshot] {
        let now = Date()
        guard now.timeIntervalSince(lastCodexScanAt) >= 3 else {
            return cachedCodexRollouts
        }
        lastCodexScanAt = now
        cachedCodexRollouts = CodexRolloutReader.loadRecent(
            from: codexSessionsURL,
            fileManager: fileManager,
            cache: &codexRolloutCache
        )
        return cachedCodexRollouts
    }

    private func newest(_ first: StatusRecord, _ second: StatusRecord?) -> StatusRecord {
        guard let second else { return first }
        return (first.updatedAt ?? .distantPast) >= (second.updatedAt ?? .distantPast) ? first : second
    }

    private func isActive(_ snapshot: AgentSnapshot) -> Bool {
        let age = Date().timeIntervalSince(snapshot.updatedAt ?? .distantPast)
        switch snapshot.state {
        case .idle:
            return false
        case .completed:
            return age <= 30
        case .running, .waitingAuthorization, .waitingReply:
            return age <= 30 * 60
        }
    }

    private func snapshotPrecedes(_ lhs: AgentSnapshot, _ rhs: AgentSnapshot) -> Bool {
        let lhsPriority = statePriority(lhs.state)
        let rhsPriority = statePriority(rhs.state)
        if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
        return snapshotDate(lhs) > snapshotDate(rhs)
    }

    private func statePriority(_ state: AgentRunState) -> Int {
        switch state {
        case .waitingAuthorization: 4
        case .waitingReply: 3
        case .running: 2
        case .completed: 1
        case .idle: 0
        }
    }

    private func snapshotDate(_ snapshot: AgentSnapshot) -> Date {
        snapshot.updatedAt ?? .distantPast
    }

    private func percentage(_ value: Double?) -> UInt8? {
        guard let value, value.isFinite else { return nil }
        return UInt8(max(0, min(100, value.rounded())))
    }

    private func remaining(fromUsed value: Double?) -> UInt8? {
        guard let used = percentage(value) else { return nil }
        return 100 - used
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    deinit {
        timer?.invalidate()
    }
}

private struct HookStatePayload: Decodable {
    var sessionID: String?
    var state: String
    var title: String?
    var modelName: String?
    var effort: String?
    var contextUsed: Double?
    var updatedAt: Double?
}

private struct ClaudeUsagePayload: Decodable {
    var fiveHourUsed: Double?
    var weeklyUsed: Double?
    var contextUsed: Double?
    var fiveHourResetsAt: Double?
    var weeklyResetsAt: Double?
    var updatedAt: Double?
}

private struct ClaudeConfigurationPayload: Decodable {
    var cachedUsageUtilization: ClaudeCachedUsage?
}

private struct ClaudeCachedUsage: Decodable {
    var fetchedAtMs: Double?
    var utilization: ClaudeCachedUtilization?
}

private struct ClaudeCachedUtilization: Decodable {
    var fiveHour: ClaudeCachedWindow?
    var sevenDay: ClaudeCachedWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeCachedWindow: Decodable {
    var utilization: Double?
    var resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
        case resetAt = "reset_at"
        case camelResetsAt = "resetsAt"
        case camelResetAt = "resetAt"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
        resetsAt = Self.decodeDate(from: container, keys: [
            .resetsAt, .resetAt, .camelResetsAt, .camelResetAt,
        ])
    }

    private static func decodeDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Date? {
        for key in keys {
            if let value = try? container.decode(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
            }
            if let value = try? container.decode(String.self, forKey: key) {
                if let numeric = Double(value) {
                    return Date(timeIntervalSince1970: numeric > 10_000_000_000 ? numeric / 1_000 : numeric)
                }
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
                    return date
                }
            }
        }
        return nil
    }
}

private struct ClaudeSessionMetadata: Decodable {
    var sessionID: String
    var name: String?
    var nameSource: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case name
        case nameSource
    }
}

private struct CodexSessionMetadata: Decodable {
    var id: String
    var threadName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

private struct StatusRecord {
    var sessionID: String
    var source: AgentSource
    var state: AgentRunState
    var title: String
    var modelName: String? = nil
    var effort: String? = nil
    var contextUsed: UInt8?
    var updatedAt: Date?
}

private struct AgentUsage {
    var fiveHourRemaining: UInt8?
    var weeklyRemaining: UInt8?
    var contextUsed: UInt8?
    var fiveHourResetsAt: Date? = nil
    var weeklyResetsAt: Date? = nil
    var updatedAt: Date?
}

struct ClaudeTranscriptUsage {
    var aiTitle: String?
    var modelName: String?
    var contextUsed: UInt8?
}

private struct ClaudeTranscriptCacheEntry {
    var modifiedAt: Date
    var fileSize: Int
    var usage: ClaudeTranscriptUsage?
}

enum ClaudeTranscriptReader {
    static func read(from url: URL) -> ClaudeTranscriptUsage? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var aiTitle: String?
        var modelName: String?
        var contextUsed: UInt8?
        contents.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            if object["type"] as? String == "ai-title",
               let value = object["aiTitle"] as? String {
                let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    aiTitle = title
                }
                return
            }

            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                return
            }

            let contextTokens = number(usage["input_tokens"])
                + number(usage["cache_creation_input_tokens"])
                + number(usage["cache_read_input_tokens"])
                + number(usage["output_tokens"])
            guard contextTokens > 0 else { return }
            modelName = message["model"] as? String
            contextUsed = ClaudeModelContextWindow.tokens(for: modelName).map {
                UInt8(max(0, min(100, (contextTokens / $0 * 100).rounded())))
            }
        }
        guard aiTitle != nil || modelName != nil || contextUsed != nil else { return nil }
        return ClaudeTranscriptUsage(
            aiTitle: aiTitle,
            modelName: modelName,
            contextUsed: contextUsed
        )
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

enum ClaudeModelContextWindow {
    private static let oneMillionPrefixes = [
        "claude-opus-5",
        "claude-sonnet-5",
        "claude-fable-5",
        "claude-mythos-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-sonnet-4-6",
    ]

    private static let twoHundredThousandPrefixes = [
        "claude-opus-4",
        "claude-sonnet-4",
        "claude-haiku-4",
        "claude-3",
        "claude-2",
        "claude-instant",
    ]

    static func tokens(for modelName: String?) -> Double? {
        guard let modelName else { return nil }
        let normalized = modelName
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        if oneMillionPrefixes.contains(where: normalized.hasPrefix) {
            return 1_000_000
        }
        if twoHundredThousandPrefixes.contains(where: normalized.hasPrefix) {
            return 200_000
        }
        return nil
    }
}

private extension AgentRunState {
    init?(hookValue: String) {
        switch hookValue.lowercased() {
        case "idle": self = .idle
        case "running": self = .running
        case "waitingauthorization", "waiting_authorization": self = .waitingAuthorization
        case "waitingreply", "waiting_reply": self = .waitingReply
        case "completed": self = .completed
        default: return nil
        }
    }
}

private enum CodexRolloutReader {
    struct Snapshot {
        var record: StatusRecord
        var usage: AgentUsage?
    }

    struct CacheEntry {
        var modifiedAt: Date
        var snapshot: Snapshot
    }

    static func loadRecent(
        from rootURL: URL,
        fileManager: FileManager,
        limit: Int = 12,
        cache: inout [URL: CacheEntry]
    ) -> [Snapshot] {
        let candidates = Array(
            recentRolloutURLs(from: rootURL, fileManager: fileManager).prefix(limit)
        )
        let retainedURLs = Set(candidates.map(\.url))
        cache = cache.filter { retainedURLs.contains($0.key) }
        return candidates.compactMap { candidate in
            if let cached = cache[candidate.url], cached.modifiedAt == candidate.modifiedAt {
                return cached.snapshot
            }
            guard let snapshot = load(from: candidate.url, modifiedAt: candidate.modifiedAt) else {
                return nil
            }
            cache[candidate.url] = CacheEntry(modifiedAt: candidate.modifiedAt, snapshot: snapshot)
            return snapshot
        }
    }

    private static func load(from fileURL: URL, modifiedAt: Date) -> Snapshot? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        var record = StatusRecord(
            sessionID: fileURL.deletingPathExtension().lastPathComponent,
            source: .codex,
            state: .idle,
            title: fileURL.deletingLastPathComponent().lastPathComponent,
            modelName: nil,
            effort: nil,
            contextUsed: nil,
            updatedAt: modifiedAt
        )
        var usage: AgentUsage?
        var contextWindow: Double?
        var turnCompleted = false

        contents.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let timestamp = date(from: object["timestamp"])
            let outerType = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? [:]

            if outerType == "session_meta" {
                record.sessionID = string(payload["id"])
                    ?? string(payload["session_id"])
                    ?? record.sessionID
                if let cwd = payload["cwd"] as? String {
                    record.title = URL(fileURLWithPath: cwd).lastPathComponent
                }
                contextWindow = number(payload["context_window"])
                    ?? number(payload["model_context_window"])
                    ?? contextWindow
            }

            if outerType == "turn_context" {
                record.modelName = string(payload["model"])
                    ?? string((payload["thread_settings"] as? [String: Any])?["model"])
                    ?? record.modelName
                record.effort = string(payload["effort"])
                    ?? string(payload["reasoning_effort"])
                    ?? string((payload["thread_settings"] as? [String: Any])?["reasoning_effort"])
                    ?? record.effort
            }

            if outerType == "event_msg", let type = payload["type"] as? String {
                switch type {
                case "user_message":
                    record.state = .running
                    turnCompleted = false
                case "task_started":
                    record.state = .running
                    turnCompleted = false
                case "task_complete", "turn_complete", "turn_aborted":
                    record.state = .completed
                    turnCompleted = true
                case "request_user_input", "elicitation_request":
                    record.state = .waitingReply
                    turnCompleted = false
                case "exec_approval_request", "apply_patch_approval_request", "request_permissions":
                    record.state = .waitingAuthorization
                    turnCompleted = false
                case "agent_reasoning", "exec_command_begin", "patch_apply_begin", "mcp_tool_call_begin",
                     "web_search_begin", "image_generation_begin", "plan_update":
                    if !turnCompleted { record.state = .running }
                case "token_count":
                    usage = parseUsage(
                        payload,
                        contextWindow: contextWindow,
                        timestamp: timestamp,
                        previous: usage
                    )
                    record.contextUsed = usage?.contextUsed ?? record.contextUsed
                default:
                    break
                }
            }

            if outerType == "response_item",
               payload["type"] as? String == "function_call",
               payload["name"] as? String == "request_user_input" {
                record.state = .waitingReply
                turnCompleted = false
            }

            if let timestamp { record.updatedAt = timestamp }
        }

        return Snapshot(record: record, usage: usage)
    }

    private static func recentRolloutURLs(
        from rootURL: URL,
        fileManager: FileManager
    ) -> [(url: URL, modifiedAt: Date)] {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }
        return candidates.sorted { $0.1 > $1.1 }
    }

    private static func parseUsage(
        _ payload: [String: Any],
        contextWindow fallbackContextWindow: Double?,
        timestamp: Date?,
        previous: AgentUsage?
    ) -> AgentUsage? {
        let rateLimits = payload["rate_limits"] as? [String: Any]
            ?? (payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any]

        var fiveHourRemaining = previous?.fiveHourRemaining
        var weeklyRemaining = previous?.weeklyRemaining
        var fiveHourResetsAt = previous?.fiveHourResetsAt
        var weeklyResetsAt = previous?.weeklyResetsAt
        for key in ["primary", "secondary"] {
            guard let window = rateLimits?[key] as? [String: Any],
                  let used = number(window["used_percent"]),
                  let minutes = number(window["window_minutes"]) else { continue }
            let remaining = UInt8(max(0, min(100, (100 - used).rounded())))
            let resetsAt = resetDate(from: window, relativeTo: timestamp)
            if minutes >= 240, minutes <= 360 {
                fiveHourRemaining = remaining
                fiveHourResetsAt = resetsAt ?? fiveHourResetsAt
            } else if minutes >= 1_440 {
                weeklyRemaining = remaining
                weeklyResetsAt = resetsAt ?? weeklyResetsAt
            }
        }

        let info = payload["info"] as? [String: Any]
        let lastUsage = info?["last_token_usage"] as? [String: Any]
        let currentTokens = number(lastUsage?["total_tokens"])
            ?? sum(number(lastUsage?["input_tokens"]), number(lastUsage?["output_tokens"]))
        let contextWindow = number(info?["model_context_window"])
            ?? number(payload["model_context_window"])
            ?? fallbackContextWindow
        let context = if let currentTokens, let contextWindow, contextWindow > 0 {
            UInt8(max(0, min(100, (currentTokens / contextWindow * 100).rounded())))
        } else {
            previous?.contextUsed
        }

        guard fiveHourRemaining != nil || weeklyRemaining != nil || context != nil else {
            return previous
        }
        return AgentUsage(
            fiveHourRemaining: fiveHourRemaining,
            weeklyRemaining: weeklyRemaining,
            contextUsed: context,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            updatedAt: timestamp ?? previous?.updatedAt
        )
    }

    private static func resetDate(
        from window: [String: Any],
        relativeTo timestamp: Date?
    ) -> Date? {
        for key in ["resets_at", "reset_at", "resetsAt", "resetAt"] {
            if let value = number(window[key]) {
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
            }
            if let value = window[key] as? String,
               let date = date(from: value) {
                return date
            }
        }
        for key in ["resets_in_seconds", "reset_after_seconds"] {
            if let seconds = number(window[key]) {
                return (timestamp ?? .now).addingTimeInterval(seconds)
            }
        }
        return nil
    }

    private static func sum(_ first: Double?, _ second: Double?) -> Double? {
        guard first != nil || second != nil else { return nil }
        return (first ?? 0) + (second ?? 0)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String where !value.isEmpty: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

}
