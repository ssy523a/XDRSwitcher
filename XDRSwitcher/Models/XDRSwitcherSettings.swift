import Foundation

struct XDRSwitcherSettings: Codable, Equatable {
    var automaticSwitchingEnabled: Bool
    var defaultPresetUniqueID: String?
    var defaultPresetName: String?
    var appRules: [AppRule]
    var switchDelaySeconds: Double
    var launchAtLoginEnabled: Bool

    static let defaultSwitchDelaySeconds = 4.0
    static let minimumSwitchDelaySeconds = 4.0
    static let maximumSwitchDelaySeconds = 4.0

    var safeSwitchDelaySeconds: Double {
        min(max(switchDelaySeconds, Self.minimumSwitchDelaySeconds), Self.maximumSwitchDelaySeconds)
    }

    static let defaults = XDRSwitcherSettings(
        automaticSwitchingEnabled: false,
        defaultPresetUniqueID: nil,
        defaultPresetName: nil,
        appRules: [],
        switchDelaySeconds: defaultSwitchDelaySeconds,
        launchAtLoginEnabled: false
    )
}
