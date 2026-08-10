import Foundation

protocol AgentPreferenceStoring: AnyObject {
    var selectedSource: AgentSource { get set }
    var defaultTool: DefaultAgentTool { get set }
}

final class UserDefaultsAgentPreferenceStore: AgentPreferenceStoring {
    private let defaults: UserDefaults
    private let selectedSourceKey = "selectedAgentSource"
    private let defaultToolKey = "defaultAgentTool"

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
}
