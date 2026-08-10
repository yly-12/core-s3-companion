import Foundation

enum CompanionProtocol {
    static let version: UInt8 = 0x01
    static let cpuUsageMessageType: UInt8 = 0x01
    static let agentStatusMessageType: UInt8 = 0x02
    static let serviceUUID = "7B3E0001-6F2B-4B7C-9B4E-3A8C1D5F2A10"
    static let writeCharacteristicUUID = "7B3E0002-6F2B-4B7C-9B4E-3A8C1D5F2A10"
}

enum CPUMessageEncodingError: Error, Equatable {
    case valueOutOfRange
}

enum CPUMessageEncoder {
    static func encode(cpuUsage: UInt8) throws -> Data {
        guard cpuUsage <= 100 else {
            throw CPUMessageEncodingError.valueOutOfRange
        }
        return Data([
            CompanionProtocol.version,
            CompanionProtocol.cpuUsageMessageType,
            cpuUsage
        ])
    }
}
