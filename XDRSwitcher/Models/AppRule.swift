import Foundation

struct AppRule: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var applicationName: String
    var presetUniqueID: String
    var presetName: String

    var id: String {
        bundleIdentifier
    }
}
