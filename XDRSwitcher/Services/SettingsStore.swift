import Foundation

enum SettingsStoreError: LocalizedError, Equatable {
    case encodingFailed(String)
    case decodingFailed(String)
    case saveVerificationFailed

    var errorDescription: String? {
        switch self {
        case let .encodingFailed(message):
            return "Unable to encode settings: \(message)"
        case let .decodingFailed(message):
            return "Unable to read saved settings: \(message)"
        case .saveVerificationFailed:
            return "Unable to verify that settings were saved."
        }
    }
}

struct SettingsStore {
    private let userDefaults: UserDefaults
    private let settingsKey: String

    init(
        userDefaults: UserDefaults = .standard,
        settingsKey: String = "XDRSwitcher.settings"
    ) {
        self.userDefaults = userDefaults
        self.settingsKey = settingsKey
    }

    var hasSavedSettings: Bool {
        userDefaults.data(forKey: settingsKey) != nil
    }

    func loadSettings() throws -> XDRSwitcherSettings? {
        guard let data = userDefaults.data(forKey: settingsKey) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(XDRSwitcherSettings.self, from: data)
        } catch {
            throw SettingsStoreError.decodingFailed(error.localizedDescription)
        }
    }

    func save(_ settings: XDRSwitcherSettings) throws {
        let data: Data

        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            throw SettingsStoreError.encodingFailed(error.localizedDescription)
        }

        userDefaults.set(data, forKey: settingsKey)

        guard userDefaults.data(forKey: settingsKey) == data else {
            throw SettingsStoreError.saveVerificationFailed
        }
    }
}
