import Foundation

protocol AgentPreferenceStoring: AnyObject {
    var selectedSource: AgentSource { get set }
}

final class UserDefaultsAgentPreferenceStore: AgentPreferenceStoring {
    private let defaults: UserDefaults
    private let key = "selectedAgentSource"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedSource: AgentSource {
        get {
            defaults.string(forKey: key).flatMap(AgentSource.init(rawValue:)) ?? .automatic
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }
}
