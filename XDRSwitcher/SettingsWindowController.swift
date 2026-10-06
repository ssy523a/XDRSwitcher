import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(appState: Binding<AppState>) {
        let hostingController = NSHostingController(
            rootView: SettingsView(appState: appState)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "XDRSwitcher Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("XDRSwitcherSettingsWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}
