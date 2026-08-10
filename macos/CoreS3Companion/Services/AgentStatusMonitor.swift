import Foundation

protocol AgentStatusMonitoring: AnyObject {
    var onSnapshots: (([AgentSnapshot]) -> Void)? { get set }
    var selectedSource: AgentSource { get set }
    func start()
    func stop()
    func refresh()
}

final class AgentStatusMonitor: AgentStatusMonitoring {
    var onSnapshots: (([AgentSnapshot]) -> Void)?
    var selectedSource: AgentSource = .automatic

    private let stateDirectoryURL: URL
    private let codexSessionsURL: URL
    private let fileManager: FileManager
    private var timer: Timer?
    private var codexRolloutCache: [URL: CodexRolloutReader.CacheEntry] = [:]
    private var cachedCodexRollouts: [CodexRolloutReader.Snapshot] = []
    private var lastCodexScanAt = Date.distantPast

    init(
        stateDirectoryURL: URL = AgentStatusMonitor.defaultStateDirectoryURL,
        codexSessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.stateDirectoryURL = stateDirectoryURL
        self.codexSessionsURL = codexSessionsURL
        self.fileManager = fileManager
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
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
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
        let claudeSnapshots = snapshots(
            from: loadHookRecords(for: .claude),
            fallbackUsage: claudeUsage
        )

        let codexHooks = loadHookRecords(for: .codex)
        let codexRollouts = loadCodexRollouts()
        let codexSnapshots = mergeCodex(hooks: codexHooks, rollouts: codexRollouts)

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

        if var fallback = candidates.max(by: { snapshotDate($0) < snapshotDate($1) }) {
            fallback.state = .idle
            onSnapshots?([fallback])
        } else {
            var idle = AgentSnapshot.idle
            if selectedSource != .automatic { idle.source = selectedSource }
            onSnapshots?([idle])
        }
    }

    private func snapshots(
        from records: [StatusRecord],
        fallbackUsage: AgentUsage?
    ) -> [AgentSnapshot] {
        records.map { record in
            AgentSnapshot(
                sessionID: record.sessionID,
                source: record.source,
                state: record.state,
                title: nonEmpty(record.title) ?? "NO ACTIVE SESSION",
                fiveHourRemaining: fallbackUsage?.fiveHourRemaining,
                weeklyRemaining: fallbackUsage?.weeklyRemaining,
                contextUsed: record.contextUsed ?? fallbackUsage?.contextUsed,
                updatedAt: record.updatedAt ?? fallbackUsage?.updatedAt
            )
        }
    }

    private func mergeCodex(
        hooks: [StatusRecord],
        rollouts: [CodexRolloutReader.Snapshot]
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
                title: nonEmpty(hook.title) ?? nonEmpty(rolloutRecord?.title) ?? "CODEX SESSION",
                fiveHourRemaining: usage?.fiveHourRemaining,
                weeklyRemaining: usage?.weeklyRemaining,
                contextUsed: rollout?.usage?.contextUsed ?? hook.contextUsed,
                updatedAt: stateRecord.updatedAt
            ))
        }

        for rollout in rolloutByID.values {
            let usage = rollout.usage ?? globalUsage
            results.append(AgentSnapshot(
                sessionID: rollout.record.sessionID,
                source: .codex,
                state: rollout.record.state,
                title: nonEmpty(rollout.record.title) ?? "CODEX SESSION",
                fiveHourRemaining: usage?.fiveHourRemaining,
                weeklyRemaining: usage?.weeklyRemaining,
                contextUsed: rollout.usage?.contextUsed,
                updatedAt: rollout.record.updatedAt
            ))
        }
        return results
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
        let url = stateDirectoryURL.appendingPathComponent("claude-usage.json")
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(ClaudeUsagePayload.self, from: data) else {
            return nil
        }
        return AgentUsage(
            fiveHourRemaining: remaining(fromUsed: payload.fiveHourUsed),
            weeklyRemaining: remaining(fromUsed: payload.weeklyUsed),
            contextUsed: percentage(payload.contextUsed),
            updatedAt: payload.updatedAt.map(Date.init(timeIntervalSince1970:))
        )
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
    var contextUsed: Double?
    var updatedAt: Double?
}

private struct ClaudeUsagePayload: Decodable {
    var fiveHourUsed: Double?
    var weeklyUsed: Double?
    var contextUsed: Double?
    var updatedAt: Double?
}

private struct StatusRecord {
    var sessionID: String
    var source: AgentSource
    var state: AgentRunState
    var title: String
    var contextUsed: UInt8?
    var updatedAt: Date?
}

private struct AgentUsage {
    var fiveHourRemaining: UInt8?
    var weeklyRemaining: UInt8?
    var contextUsed: UInt8?
    var updatedAt: Date?
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

            if outerType == "event_msg", let type = payload["type"] as? String {
                switch type {
                case "user_message":
                    if let message = payload["message"] as? String, !message.isEmpty {
                        record.title = firstLine(message)
                    }
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
        for key in ["primary", "secondary"] {
            guard let window = rateLimits?[key] as? [String: Any],
                  let used = number(window["used_percent"]),
                  let minutes = number(window["window_minutes"]) else { continue }
            let remaining = UInt8(max(0, min(100, (100 - used).rounded())))
            if minutes >= 240, minutes <= 360 {
                fiveHourRemaining = remaining
            } else if minutes >= 1_440 {
                weeklyRemaining = remaining
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
            updatedAt: timestamp ?? previous?.updatedAt
        )
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

    private static func firstLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
    }
}
