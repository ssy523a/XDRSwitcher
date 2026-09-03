import Foundation

struct XDRSwitcherSettings: Codable, Equatable {
    var automaticSwitchingEnabled: Bool
    var defaultPresetUniqueID: String?
    var defaultPresetName: String?
    var appRules: [AppRule]
    var switchDelaySeconds: Double
    var launchAtLoginEnabled: Bool

    static let defaultSwitchDelaySeconds = 0.7

    static let defaults = XDRSwitcherSettings(
        automaticSwitchingEnabled: false,
        defaultPresetUniqueID: nil,
        defaultPresetName: nil,
        appRules: [],
        switchDelaySeconds: defaultSwitchDelaySeconds,
        launchAtLoginEnabled: false
    )
}
