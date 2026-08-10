import Foundation

protocol AgentPreferenceStoring: AnyObject {
    var selectedSource: AgentSource { get set }
    var defaultTool: DefaultAgentTool { get set }
    var displaySleepTimeout: DisplaySleepTimeout { get set }
}

final class UserDefaultsAgentPreferenceStore: AgentPreferenceStoring {
    private let defaults: UserDefaults
    private let selectedSourceKey = "selectedAgentSource"
    private let defaultToolKey = "defaultAgentTool"
    private let displaySleepTimeoutKey = "displaySleepTimeoutMinutes"

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

    var displaySleepTimeout: DisplaySleepTimeout {
        get {
            guard defaults.object(forKey: displaySleepTimeoutKey) != nil else {
                return .never
            }
            let value = UInt8(clamping: defaults.integer(forKey: displaySleepTimeoutKey))
            return DisplaySleepTimeout(rawValue: value) ?? .never
        }
        set {
            defaults.set(Int(newValue.rawValue), forKey: displaySleepTimeoutKey)
        }
    }
}
