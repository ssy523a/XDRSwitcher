import AppKit

@main
@MainActor
final class XDRSwitcherAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: ApplicationCoordinator?

    static func main() {
        let application = NSApplication.shared
        let delegate = XDRSwitcherAppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = ApplicationCoordinator()
        print("[XDRSwitcher] AppKit menu bar initialized")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
