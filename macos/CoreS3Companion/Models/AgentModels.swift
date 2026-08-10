import Foundation

enum AgentSource: String, CaseIterable, Codable, Identifiable {
    case automatic
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "自动选择"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var protocolValue: UInt8 {
        switch self {
        case .automatic: 0
        case .claude: 1
        case .codex: 2
        }
    }
}

enum DefaultAgentTool: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var source: AgentSource {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }

    var displayName: String { source.displayName }
}

enum AgentRunState: UInt8, Codable, CaseIterable {
    case idle = 0
    case running = 1
    case waitingAuthorization = 2
    case waitingReply = 3
    case completed = 4

    var shortLabel: String {
        switch self {
        case .idle: "IDLE"
        case .running: "RUN"
        case .waitingAuthorization: "AUTH"
        case .waitingReply: "REPLY"
        case .completed: "DONE"
        }
    }

    var displayName: String {
        switch self {
        case .idle: "空闲"
        case .running: "运行中"
        case .waitingAuthorization: "等待授权"
        case .waitingReply: "等待用户回复"
        case .completed: "已完成"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle.dotted"
        case .running: "bolt.fill"
        case .waitingAuthorization: "lock.fill"
        case .waitingReply: "bubble.left.fill"
        case .completed: "checkmark.circle.fill"
        }
    }
}

struct AgentSnapshot: Equatable {
    var sessionID: String = "default"
    var source: AgentSource
    var state: AgentRunState
    var title: String
    var modelName: String? = nil
    var effort: String? = nil
    var fiveHourRemaining: UInt8?
    var weeklyRemaining: UInt8?
    var contextUsed: UInt8?
    var updatedAt: Date?

    static let idle = AgentSnapshot(
        sessionID: "idle",
        source: .claude,
        state: .idle,
        title: "NO ACTIVE SESSION",
        modelName: nil,
        effort: nil,
        fiveHourRemaining: nil,
        weeklyRemaining: nil,
        contextUsed: nil,
        updatedAt: nil
    )
}

enum DisplayMetadata {
    static let maximumModelByteCount = 32
    static let maximumModelDisplayUnits = 14
    static let maximumEffortByteCount = 8

    static func model(_ value: String?) -> String {
        sanitize(
            value,
            maximumByteCount: maximumModelByteCount,
            maximumDisplayUnits: maximumModelDisplayUnits
        )
    }

    static func effort(_ value: String?) -> String {
        sanitize(
            value,
            maximumByteCount: maximumEffortByteCount,
            maximumDisplayUnits: maximumEffortByteCount
        )
    }

    private static func sanitize(
        _ value: String?,
        maximumByteCount: Int,
        maximumDisplayUnits: Int
    ) -> String {
        guard let value else { return "" }
        let normalized = value
            .precomposedStringWithCanonicalMapping
            .folding(options: [.widthInsensitive], locale: .current)
            .uppercased()

        var result = ""
        var byteCount = 0
        var displayUnits = 0
        var pendingSpace = false
        for character in normalized {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            guard character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                continue
            }
            let text = String(character)
            let bytes = text.utf8.count
            let units = character.unicodeScalars.allSatisfy(\.isASCII) ? 1 : 2
            let space = pendingSpace ? 1 : 0
            guard byteCount + space + bytes <= maximumByteCount,
                  displayUnits + space + units <= maximumDisplayUnits else {
                break
            }
            if pendingSpace {
                result.append(" ")
                byteCount += 1
                displayUnits += 1
            }
            result.append(character)
            byteCount += bytes
            displayUnits += units
            pendingSpace = false
        }
        return result
    }
}

enum AgentIntegrationKind: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var source: AgentSource {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }

    var displayName: String { source.displayName }
}

struct AgentIntegrationStatus: Equatable {
    var kind: AgentIntegrationKind
    var isInstalled: Bool
    var detail: String
    var configPath: String
}

enum DisplayTitle {
    static let maximumByteCount = 60
    static let maximumDisplayUnits = 34

    static func sanitize(_ value: String, maximumByteCount: Int = maximumByteCount) -> String {
        let normalized = value
            .precomposedStringWithCanonicalMapping
            .folding(options: [.widthInsensitive], locale: .current)
            .uppercased()

        var result = ""
        var byteCount = 0
        var displayUnits = 0
        var pendingSpace = false

        for character in normalized {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            guard character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                continue
            }

            let text = String(character)
            let characterBytes = text.utf8.count
            let characterUnits = character.unicodeScalars.allSatisfy(\.isASCII) ? 1 : 2
            let spaceBytes = pendingSpace ? 1 : 0
            let spaceUnits = pendingSpace ? 1 : 0
            guard byteCount + spaceBytes + characterBytes <= maximumByteCount,
                  displayUnits + spaceUnits + characterUnits <= maximumDisplayUnits else {
                break
            }
            if pendingSpace {
                result.append(" ")
                byteCount += 1
                displayUnits += 1
            }
            result.append(character)
            byteCount += characterBytes
            displayUnits += characterUnits
            pendingSpace = false
        }

        return result.isEmpty ? "AGENT SESSION" : result
    }
}
