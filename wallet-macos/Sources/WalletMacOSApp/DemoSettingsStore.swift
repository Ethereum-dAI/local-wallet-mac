import Foundation

struct DemoSettingsStore {
    private enum Keys {
        static let testnetModeEnabled = "com.localwallet.demo.testnet-mode-enabled"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isTestnetModeEnabled: Bool {
        if defaults.object(forKey: Keys.testnetModeEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.testnetModeEnabled)
    }

    func setTestnetModeEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Keys.testnetModeEnabled)
    }
}
