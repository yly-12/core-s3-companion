import Foundation

protocol PairedDeviceStoring: AnyObject {
    var deviceID: UUID? { get set }
    var deviceName: String? { get set }
    func clear()
}

final class UserDefaultsPairedDeviceStore: PairedDeviceStoring {
    private enum Key {
        static let deviceID = "pairedDeviceID"
        static let deviceName = "pairedDeviceName"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var deviceID: UUID? {
        get {
            defaults.string(forKey: Key.deviceID).flatMap(UUID.init(uuidString:))
        }
        set {
            defaults.set(newValue?.uuidString, forKey: Key.deviceID)
        }
    }

    var deviceName: String? {
        get { defaults.string(forKey: Key.deviceName) }
        set { defaults.set(newValue, forKey: Key.deviceName) }
    }

    func clear() {
        defaults.removeObject(forKey: Key.deviceID)
        defaults.removeObject(forKey: Key.deviceName)
    }
}

