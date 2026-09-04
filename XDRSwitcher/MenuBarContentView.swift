import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Binding var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            showAboutDialog()
        } label: {
            Label("About XDR Switcher", systemImage: "info.circle")
        }

        Divider()

        Toggle("Automatic Switching", isOn: automaticSwitchingBinding)

        Divider()

        Text("Current Application: \(appState.currentApplicationName)")
        Text("Current Reference Mode: \(appState.currentReferenceModeName)")

        if let automaticSwitchingErrorMessage = appState.automaticSwitchingErrorMessage {
            Text("Recent Error: \(automaticSwitchingErrorMessage)")
        }

        Divider()

        Button {
            openSettingsWindow()
        } label: {
            Label("Open Settings", systemImage: "gearshape")
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit XDRSwitcher", systemImage: "xmark.square")
        }
    }

    private func openSettingsWindow() {
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showAboutDialog() {
        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "About XDRSwitcher"
        alert.informativeText = "\(aboutTitle)\nSeo, Se-young\nssy523a@gmail.com\n\nThis app uses dynamically loaded private CoreDisplay APIs to read and change Reference Modes. macOS updates may change or remove that behavior."
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var automaticSwitchingBinding: Binding<Bool> {
        Binding(
            get: { appState.isAutomaticSwitchingEnabled },
            set: { appState.setAutomaticSwitchingEnabled($0) }
        )
    }

    private var aboutTitle: String {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "XDRSwitcher"
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let shortVersion, let buildVersion {
            return "\(appName) \(shortVersion) (\(buildVersion))"
        }

        if let shortVersion {
            return "\(appName) \(shortVersion)"
        }

        return appName
    }
}
