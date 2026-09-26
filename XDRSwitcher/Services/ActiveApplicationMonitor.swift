import AppKit
import Foundation

struct ActiveApplicationInfo: Equatable {
    let localizedName: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let processIdentifier: pid_t

    var displayName: String {
        localizedName.isEmpty ? (bundleIdentifier ?? "Not Available") : localizedName
    }
}

enum ApplicationLifecycleEvent: Equatable {
    case launched(ActiveApplicationInfo)
    case activated(ActiveApplicationInfo)
    case terminated(ActiveApplicationInfo)
}

protocol ActiveApplicationWorkspaceProviding {
    var frontmostApplication: NSRunningApplication? { get }
    var notificationCenter: NotificationCenter { get }
}

struct ActiveApplicationWorkspace: ActiveApplicationWorkspaceProviding {
    var frontmostApplication: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
    var notificationCenter: NotificationCenter { NSWorkspace.shared.notificationCenter }
}

final class ActiveApplicationMonitor {
    private let workspace: any ActiveApplicationWorkspaceProviding
    private var observers: [NSObjectProtocol] = []
    private var onEvent: (@MainActor (ApplicationLifecycleEvent) -> Void)?

    init(workspace: any ActiveApplicationWorkspaceProviding = ActiveApplicationWorkspace()) {
        self.workspace = workspace
    }

    deinit {
        for observer in observers {
            workspace.notificationCenter.removeObserver(observer)
        }
    }

    @MainActor
    func currentApplicationInfo() -> ActiveApplicationInfo? {
        workspace.frontmostApplication.map(Self.info)
    }

    @MainActor
    func start(onEvent: @escaping @MainActor (ApplicationLifecycleEvent) -> Void) {
        self.onEvent = onEvent

        if let application = workspace.frontmostApplication {
            onEvent(.activated(Self.info(from: application)))
        }

        guard observers.isEmpty else { return }

        observe(NSWorkspace.didLaunchApplicationNotification, event: ApplicationLifecycleEvent.launched)
        observe(NSWorkspace.didActivateApplicationNotification, event: ApplicationLifecycleEvent.activated)
        observe(NSWorkspace.didTerminateApplicationNotification, event: ApplicationLifecycleEvent.terminated)
    }

    @MainActor
    private func observe(
        _ name: Notification.Name,
        event: @escaping (ActiveApplicationInfo) -> ApplicationLifecycleEvent
    ) {
        observers.append(
            workspace.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.onEvent?(event(Self.info(from: application)))
                }
            }
        )
    }

    @MainActor
    private static func info(from application: NSRunningApplication) -> ActiveApplicationInfo {
        ActiveApplicationInfo(
            localizedName: application.localizedName ?? "",
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL,
            processIdentifier: application.processIdentifier
        )
    }
}
