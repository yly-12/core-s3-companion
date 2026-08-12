import Foundation

struct ClaudeUsageRefreshSnapshot: Equatable {
    var fiveHourRemaining: UInt8?
    var weeklyRemaining: UInt8?
    var updatedAt: Date
}

enum ClaudeUsageRefreshOutcome: Equatable {
    case cacheAdvanced
    case commandOutput(ClaudeUsageRefreshSnapshot)
}

protocol ClaudeUsageRefreshing: AnyObject {
    func refresh(
        configurationURL: URL,
        completion: @escaping (ClaudeUsageRefreshOutcome?) -> Void
    )
}

final class ClaudeCLIUsageRefresher: ClaudeUsageRefreshing {
    static let arguments = [
        "--safe-mode",
        "--no-session-persistence",
        "--tools", "",
        "--max-turns", "1",
        "--output-format", "json",
        "-p", "/usage",
    ]

    private let queue = DispatchQueue(
        label: "com.cores3companion.claude-usage",
        qos: .utility
    )
    private let timeout: TimeInterval
    private let currentDate: () -> Date

    init(timeout: TimeInterval = 20, currentDate: @escaping () -> Date = Date.init) {
        self.timeout = timeout
        self.currentDate = currentDate
    }

    func refresh(
        configurationURL: URL,
        completion: @escaping (ClaudeUsageRefreshOutcome?) -> Void
    ) {
        queue.async { [timeout, currentDate] in
            let previousFetchedAtMs = Self.cachedFetchedAtMs(at: configurationURL)
            let output = Self.runClaudeUsage(timeout: timeout)
            let refreshedFetchedAtMs = Self.cachedFetchedAtMs(at: configurationURL)

            let outcome: ClaudeUsageRefreshOutcome?
            if let output,
               let snapshot = Self.parseVerifiedResponse(output, now: currentDate()) {
                if let refreshedFetchedAtMs,
                   refreshedFetchedAtMs > (previousFetchedAtMs ?? -.infinity) {
                    outcome = .cacheAdvanced
                } else {
                    outcome = .commandOutput(snapshot)
                }
            } else {
                outcome = nil
            }
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }

    static func cachedFetchedAtMs(at configurationURL: URL) -> Double? {
        guard let data = try? Data(contentsOf: configurationURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any] else {
            return nil
        }
        return number(cache["fetchedAtMs"])
    }

    static func parseVerifiedResponse(
        _ data: Data,
        now: Date = .now
    ) -> ClaudeUsageRefreshSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["subtype"] as? String == "success",
              root["is_error"] as? Bool == false,
              number(root["num_turns"]) == 0,
              number(root["total_cost_usd"]) == 0,
              let usage = root["usage"] as? [String: Any],
              tokenCountIsZero(usage, key: "input_tokens"),
              tokenCountIsZero(usage, key: "cache_creation_input_tokens"),
              tokenCountIsZero(usage, key: "cache_read_input_tokens"),
              tokenCountIsZero(usage, key: "output_tokens"),
              (root["modelUsage"] as? [String: Any])?.isEmpty != false,
              let result = root["result"] as? String else {
            return nil
        }

        let fiveHourUsed = percentage(
            in: result,
            pattern: #"Current session:\s*([0-9]+(?:\.[0-9]+)?)%\s+used"#
        )
        let weeklyUsed = percentage(
            in: result,
            pattern: #"Current week[^:\n]*:\s*([0-9]+(?:\.[0-9]+)?)%\s+used"#
        )
        guard fiveHourUsed != nil || weeklyUsed != nil else { return nil }
        return ClaudeUsageRefreshSnapshot(
            fiveHourRemaining: remaining(fromUsed: fiveHourUsed),
            weeklyRemaining: remaining(fromUsed: weeklyUsed),
            updatedAt: now
        )
    }

    private static func runClaudeUsage(timeout: TimeInterval) -> Data? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude"] + arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = environmentWithClaudeSearchPaths()
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    private static func environmentWithClaudeSearchPaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferredPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = (preferredPaths + existing)
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) { paths.append(path) }
            }
            .joined(separator: ":")
        return environment
    }

    private static func tokenCountIsZero(_ usage: [String: Any], key: String) -> Bool {
        number(usage[key]) == 0
    }

    private static func percentage(in text: String, pattern: String) -> Double? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]),
              value.isFinite,
              (0...100).contains(value) else {
            return nil
        }
        return value
    }

    private static func remaining(fromUsed value: Double?) -> UInt8? {
        guard let value else { return nil }
        return 100 - UInt8(max(0, min(100, value.rounded())))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        default:
            return nil
        }
    }
}
