import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let automaticSwitchingItem = NSMenuItem()
    private let currentApplicationItem = NSMenuItem()
    private let currentReferenceModeItem = NSMenuItem()
    private let recentErrorItem = NSMenuItem()

    private let onAutomaticSwitchingToggle: () -> Void
    private let onOpenSettings: () -> Void

    private var appState: AppState

    init(
        appState: AppState,
        onAutomaticSwitchingToggle: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.appState = appState
        self.onAutomaticSwitchingToggle = onAutomaticSwitchingToggle
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
        configureMenu()
        update(with: appState)
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func update(with appState: AppState) {
        self.appState = appState
        automaticSwitchingItem.state = appState.isAutomaticSwitchingEnabled ? .on : .off
        currentApplicationItem.title = "Current Application: \(appState.currentApplicationName)"
        currentReferenceModeItem.title = "Current Reference Mode: \(appState.currentReferenceModeName)"

        if let error = appState.automaticSwitchingErrorMessage {
            recentErrorItem.title = "Recent Error: \(error)"
            recentErrorItem.isHidden = false
        } else {
            recentErrorItem.isHidden = true
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        update(with: appState)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "XDRSwitcher")
        button.toolTip = "XDRSwitcher"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(
            item(
                title: "About XDRSwitcher",
                action: #selector(showAbout)
            )
        )
        menu.addItem(.separator())

        automaticSwitchingItem.title = "Automatic Switching"
        automaticSwitchingItem.target = self
        automaticSwitchingItem.action = #selector(toggleAutomaticSwitching)
        automaticSwitchingItem.isEnabled = true
        menu.addItem(automaticSwitchingItem)

        menu.addItem(.separator())

        currentApplicationItem.isEnabled = false
        currentReferenceModeItem.isEnabled = false
        recentErrorItem.isEnabled = false
        menu.addItem(currentApplicationItem)
        menu.addItem(currentReferenceModeItem)
        menu.addItem(recentErrorItem)

        menu.addItem(.separator())
        menu.addItem(
            item(
                title: "Open Settings",
                action: #selector(openSettings)
            )
        )

        menu.addItem(.separator())
        menu.addItem(
            item(
                title: "Quit XDRSwitcher",
                action: #selector(quit)
            )
        )
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func toggleAutomaticSwitching() {
        onAutomaticSwitchingToggle()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "About XDRSwitcher"
        alert.informativeText = "\(aboutTitle)\nSeo, Se-young\nssy523a@gmail.com\n\nThis app uses dynamically loaded private CoreDisplay APIs to read and change Reference Modes. macOS updates may change or remove that behavior."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
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
