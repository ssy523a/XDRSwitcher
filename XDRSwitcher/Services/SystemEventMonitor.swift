import AppKit
import CoreGraphics
import Foundation

final class SystemEventMonitor {
    private let applicationNotificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private var notificationObservers: [NSObjectProtocol] = []
    private var isDisplayCallbackRegistered = false
    private var isDisplayConfigurationChanging = false
    private var displayConfigurationCompletionTask: Task<Void, Never>?

    private var onWillTerminate: (@MainActor () -> Void)?
    private var onWillSleep: (@MainActor () -> Void)?
    private var onDidWake: (@MainActor () -> Void)?
    private var onDisplayConfigurationWillChange: (@MainActor () -> Void)?
    private var onDisplayConfigurationDidChange: (@MainActor () -> Void)?

    init(
        applicationNotificationCenter: NotificationCenter = NotificationCenter.default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.applicationNotificationCenter = applicationNotificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    deinit {
        stop()
    }

    @MainActor
    func start(
        onWillTerminate: @escaping @MainActor () -> Void,
        onWillSleep: @escaping @MainActor () -> Void,
        onDidWake: @escaping @MainActor () -> Void,
        onDisplayConfigurationWillChange: @escaping @MainActor () -> Void,
        onDisplayConfigurationDidChange: @escaping @MainActor () -> Void
    ) {
        self.onWillTerminate = onWillTerminate
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
        self.onDisplayConfigurationWillChange = onDisplayConfigurationWillChange
        self.onDisplayConfigurationDidChange = onDisplayConfigurationDidChange

        registerNotificationObserversIfNeeded()
        registerDisplayCallbackIfNeeded()
    }

    private func stop() {
        for observer in notificationObservers {
            applicationNotificationCenter.removeObserver(observer)
            workspaceNotificationCenter.removeObserver(observer)
        }

        notificationObservers = []
        displayConfigurationCompletionTask?.cancel()
        displayConfigurationCompletionTask = nil

        if isDisplayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
            isDisplayCallbackRegistered = false
        }
    }

    @MainActor
    private func registerNotificationObserversIfNeeded() {
        guard notificationObservers.isEmpty else {
            return
        }

        notificationObservers.append(
            applicationNotificationCenter.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onWillTerminate?()
                }
            }
        )

        notificationObservers.append(
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onWillSleep?()
                }
            }
        )

        notificationObservers.append(
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onDidWake?()
                }
            }
        )
    }

    @MainActor
    private func registerDisplayCallbackIfNeeded() {
        guard !isDisplayCallbackRegistered else {
            return
        }

        let error = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        if error == .success {
            isDisplayCallbackRegistered = true
        } else {
            print("XDRSwitcher display configuration callback registration failed: \(error)")
        }
    }

    @MainActor
    private func handleDisplayReconfiguration(flags: CGDisplayChangeSummaryFlags) {
        if flags.contains(.beginConfigurationFlag) {
            displayConfigurationCompletionTask?.cancel()

            guard !isDisplayConfigurationChanging else {
                return
            }

            isDisplayConfigurationChanging = true
            onDisplayConfigurationWillChange?()
            return
        }

        displayConfigurationCompletionTask?.cancel()
        displayConfigurationCompletionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else {
                return
            }

            self.isDisplayConfigurationChanging = false
            self.displayConfigurationCompletionTask = nil
            self.onDisplayConfigurationDidChange?()
        }
    }

    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else {
            return
        }

        let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        Task { @MainActor in
            monitor.handleDisplayReconfiguration(flags: flags)
        }
    }
}
