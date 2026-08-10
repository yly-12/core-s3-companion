import Foundation

enum AgentStatusMessageEncodingError: Error, Equatable {
    case valueOutOfRange
    case titleTooLong
    case modelTooLong
    case effortTooLong
}

enum AgentStatusMessageEncoder {
    static let unknownValue: UInt8 = 0xFF
    static let headerSize = 8

    static func encode(_ snapshot: AgentSnapshot) throws -> Data {
        let title = DisplayTitle.sanitize(snapshot.title)
        let titleBytes = Array(title.utf8)
        let modelBytes = Array(DisplayMetadata.model(snapshot.modelName).utf8)
        let effortBytes = Array(DisplayMetadata.effort(snapshot.effort).utf8)
        guard titleBytes.count <= DisplayTitle.maximumByteCount else {
            throw AgentStatusMessageEncodingError.titleTooLong
        }
        guard modelBytes.count <= DisplayMetadata.maximumModelByteCount else {
            throw AgentStatusMessageEncodingError.modelTooLong
        }
        guard effortBytes.count <= DisplayMetadata.maximumEffortByteCount else {
            throw AgentStatusMessageEncodingError.effortTooLong
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
        bytes.append(UInt8(modelBytes.count))
        bytes.append(UInt8(effortBytes.count))
        bytes.append(contentsOf: modelBytes)
        bytes.append(contentsOf: effortBytes)
        return Data(bytes)
    }
}
