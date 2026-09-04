import AppKit
import Foundation
import UniformTypeIdentifiers

struct SelectedApplication: Equatable {
    let appDisplayName: String
    let bundleIdentifier: String
    let appPath: String
}

enum ApplicationSelectionError: LocalizedError, Equatable {
    case missingBundleIdentifier(String)
    case invalidApplication(String)

    var errorDescription: String? {
        switch self {
        case let .missingBundleIdentifier(path):
            return "The selected app does not have a Bundle Identifier and cannot be added as a rule: \(path)"
        case let .invalidApplication(path):
            return "The selected item is not a readable application bundle: \(path)"
        }
    }
}

struct ApplicationSelectionService {
    @MainActor
    func selectApplication() throws -> SelectedApplication? {
        let panel = NSOpenPanel()
        panel.title = "Add Application"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let appURL = panel.url else {
            return nil
        }

        guard let bundle = Bundle(url: appURL) else {
            throw ApplicationSelectionError.invalidApplication(appURL.path)
        }

        guard let bundleIdentifier = bundle.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw ApplicationSelectionError.missingBundleIdentifier(appURL.path)
        }

        let displayName = FileManager.default.displayName(atPath: appURL.path)

        return SelectedApplication(
            appDisplayName: displayName,
            bundleIdentifier: bundleIdentifier,
            appPath: appURL.path
        )
    }
}
