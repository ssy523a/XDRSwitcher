import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Binding var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("XDR Switcher")
            .font(.headline)

        Divider()

        Toggle("Automatic Switching", isOn: automaticSwitchingBinding)

        Divider()

        Text("Current Application: \(appState.currentApplicationName)")
        Text("Current Reference Mode: \(appState.currentReferenceModeName)")

        if let automaticSwitchingErrorMessage = appState.automaticSwitchingErrorMessage {
            Text("Recent Error: \(automaticSwitchingErrorMessage)")
        }

        Divider()

        Button("Open Settings") {
            openSettingsWindow()
        }

        Divider()

        Button("Quit XDRSwitcher") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openSettingsWindow() {
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var automaticSwitchingBinding: Binding<Bool> {
        Binding(
            get: { appState.isAutomaticSwitchingEnabled },
            set: { appState.setAutomaticSwitchingEnabled($0) }
        )
    }
}
