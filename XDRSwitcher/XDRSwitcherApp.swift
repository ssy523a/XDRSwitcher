import AppKit
import SwiftUI

@main
struct XDRSwitcherApp: App {
    @State private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("XDRSwitcher", systemImage: "display") {
            MenuBarContentView(appState: $appState)
        }

        Settings {
            SettingsView(appState: $appState)
        }
    }
}
