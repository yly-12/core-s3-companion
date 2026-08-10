import Foundation

enum AgentStatusMessageEncodingError: Error, Equatable {
    case valueOutOfRange
    case titleTooLong
}

enum AgentStatusMessageEncoder {
    static let unknownValue: UInt8 = 0xFF
    static let headerSize = 8

    static func encode(_ snapshot: AgentSnapshot) throws -> Data {
        let title = DisplayTitle.sanitize(snapshot.title)
        let titleBytes = Array(title.utf8)
        guard titleBytes.count <= DisplayTitle.maximumByteCount else {
            throw AgentStatusMessageEncodingError.titleTooLong
        }

        let metrics = [snapshot.fiveHourRemaining, snapshot.weeklyRemaining, snapshot.contextUsed]
        guard metrics.allSatisfy({ $0 == nil || $0! <= 100 }) else {
            throw AgentStatusMessageEncodingError.valueOutOfRange
        }

        var bytes: [UInt8] = [
            CompanionProtocol.version,
            CompanionProtocol.agentStatusMessageType,
            snapshot.state.rawValue,
            snapshot.source.protocolValue,
            snapshot.fiveHourRemaining ?? unknownValue,
            snapshot.weeklyRemaining ?? unknownValue,
            snapshot.contextUsed ?? unknownValue,
            UInt8(titleBytes.count),
        ]
        bytes.append(contentsOf: titleBytes)
        return Data(bytes)
    }
}

