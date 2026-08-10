import Foundation

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int

    var shortIdentifier: String {
        String(id.uuidString.suffix(6))
    }
}

enum BLEConnectionState: Equatable {
    case idle
    case bluetoothUnavailable(String)
    case scanning
    case connecting(UUID)
    case discovering(UUID)
    case connected(UUID)
    case failed(String)
}

enum BLESelectionPolicy {
    static func shouldAutoConnect(discoveredID: UUID, targetID: UUID?) -> Bool {
        guard let targetID else { return false }
        return discoveredID == targetID
    }

    static func hasRequiredCharacteristic(
        _ characteristicUUIDs: [String],
        requiredUUID: String = CompanionProtocol.writeCharacteristicUUID
    ) -> Bool {
        characteristicUUIDs.contains {
            $0.caseInsensitiveCompare(requiredUUID) == .orderedSame
        }
    }
}

