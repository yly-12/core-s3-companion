import Foundation

protocol AgentPreferenceStoring: AnyObject {
    var selectedSource: AgentSource { get set }
    var defaultTool: DefaultAgentTool { get set }
    var displaySleepTimeoutOnBattery: DisplaySleepTimeout { get set }
    var displaySleepTimeoutOnExternalPower: DisplaySleepTimeout { get set }
}

final class UserDefaultsAgentPreferenceStore: AgentPreferenceStoring {
    private let defaults: UserDefaults
    private let selectedSourceKey = "selectedAgentSource"
    private let defaultToolKey = "defaultAgentTool"
    private let legacyDisplaySleepTimeoutKey = "displaySleepTimeoutMinutes"
    private let batteryDisplaySleepTimeoutKey = "displaySleepTimeoutOnBatteryMinutes"
    private let externalPowerDisplaySleepTimeoutKey = "displaySleepTimeoutOnExternalPowerMinutes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedSource: AgentSource {
        get {
            defaults.string(forKey: selectedSourceKey).flatMap(AgentSource.init(rawValue:)) ?? .automatic
        }
        set {
            defaults.set(newValue.rawValue, forKey: selectedSourceKey)
        }
    }

    var defaultTool: DefaultAgentTool {
        get {
            defaults.string(forKey: defaultToolKey).flatMap(DefaultAgentTool.init(rawValue:)) ?? .claude
        }
        set {
            defaults.set(newValue.rawValue, forKey: defaultToolKey)
        }
    }

    var displaySleepTimeoutOnBattery: DisplaySleepTimeout {
        get {
            if defaults.object(forKey: batteryDisplaySleepTimeoutKey) != nil {
                let value = UInt8(clamping: defaults.integer(forKey: batteryDisplaySleepTimeoutKey))
                return DisplaySleepTimeout(rawValue: value) ?? .never
            }
            guard defaults.object(forKey: legacyDisplaySleepTimeoutKey) != nil else {
                return .never
            }
            let value = UInt8(clamping: defaults.integer(forKey: legacyDisplaySleepTimeoutKey))
            return DisplaySleepTimeout(rawValue: value) ?? .never
        }
        set {
            defaults.set(Int(newValue.rawValue), forKey: batteryDisplaySleepTimeoutKey)
        }
    }

    var displaySleepTimeoutOnExternalPower: DisplaySleepTimeout {
        get {
            guard defaults.object(forKey: externalPowerDisplaySleepTimeoutKey) != nil else {
                return .never
            }
            let value = UInt8(clamping: defaults.integer(forKey: externalPowerDisplaySleepTimeoutKey))
            return DisplaySleepTimeout(rawValue: value) ?? .never
        }
        set {
            defaults.set(Int(newValue.rawValue), forKey: externalPowerDisplaySleepTimeoutKey)
        }
    }
}
