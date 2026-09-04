import AppKit
import Foundation

struct ActiveApplicationInfo: Equatable {
    let localizedName: String
    let bundleIdentifier: String?
    let bundleURL: URL?

    var displayName: String {
        if !localizedName.isEmpty {
            return localizedName
        }

        return bundleIdentifier ?? "Not Available"
    }
}

protocol ActiveApplicationWorkspaceProviding {
    var frontmostApplication: NSRunningApplication? { get }
    var notificationCenter: NotificationCenter { get }
}

struct ActiveApplicationWorkspace: ActiveApplicationWorkspaceProviding {
    var frontmostApplication: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    var notificationCenter: NotificationCenter {
        NSWorkspace.shared.notificationCenter
    }
}

final class ActiveApplicationMonitor {
    private let workspace: any ActiveApplicationWorkspaceProviding
    private var activationObserver: NSObjectProtocol?
    private var onActiveApplicationChange: (@MainActor (ActiveApplicationInfo) -> Void)?

    init(workspace: any ActiveApplicationWorkspaceProviding = ActiveApplicationWorkspace()) {
        self.workspace = workspace
    }

    deinit {
        if let activationObserver {
            workspace.notificationCenter.removeObserver(activationObserver)
        }
    }

    func currentApplicationInfo() -> ActiveApplicationInfo? {
        guard let frontmostApplication = workspace.frontmostApplication else {
            return nil
        }

        return Self.info(from: frontmostApplication)
    }

    @MainActor
    func start(onChange: @escaping @MainActor (ActiveApplicationInfo) -> Void) {
        onActiveApplicationChange = onChange

        if let frontmostApplication = workspace.frontmostApplication {
            onChange(Self.info(from: frontmostApplication))
        }

        guard activationObserver == nil else {
            return
        }

        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            let applicationInfo = Self.info(from: application)
            Task { @MainActor [weak self] in
                self?.onActiveApplicationChange?(applicationInfo)
            }
        }
    }

    private static func info(from application: NSRunningApplication) -> ActiveApplicationInfo {
        ActiveApplicationInfo(
            localizedName: application.localizedName ?? "",
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL
        )
    }
}
