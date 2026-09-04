import Foundation

struct AppRule: Codable, Equatable, Identifiable {
    var id: UUID
    var appDisplayName: String
    var bundleIdentifier: String
    var appPath: String?
    var presetUniqueID: String
    var presetName: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        appDisplayName: String,
        bundleIdentifier: String,
        appPath: String?,
        presetUniqueID: String,
        presetName: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.appDisplayName = appDisplayName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.presetUniqueID = presetUniqueID
        self.presetName = presetName
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case appDisplayName
        case applicationName
        case bundleIdentifier
        case appPath
        case presetUniqueID
        case presetName
        case enabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        let appDisplayName = try container.decodeIfPresent(String.self, forKey: .appDisplayName)
            ?? container.decodeIfPresent(String.self, forKey: .applicationName)
            ?? bundleIdentifier

        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            appDisplayName: appDisplayName,
            bundleIdentifier: bundleIdentifier,
            appPath: try container.decodeIfPresent(String.self, forKey: .appPath),
            presetUniqueID: try container.decode(String.self, forKey: .presetUniqueID),
            presetName: try container.decode(String.self, forKey: .presetName),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(appDisplayName, forKey: .appDisplayName)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(appPath, forKey: .appPath)
        try container.encode(presetUniqueID, forKey: .presetUniqueID)
        try container.encode(presetName, forKey: .presetName)
        try container.encode(enabled, forKey: .enabled)
    }
}
