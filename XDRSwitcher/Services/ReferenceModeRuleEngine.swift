import Foundation

struct ReferenceModeRuleTarget: Equatable {
    let uniqueID: String
    let name: String
    let source: ReferenceModeRuleTargetSource
}

enum ReferenceModeRuleTargetSource: Equatable {
    case appRule(bundleIdentifier: String)
    case defaultPreset
}

enum ReferenceModeRuleEngineError: LocalizedError, Equatable {
    case missingDefaultPreset
    case unavailablePreset(name: String, uniqueID: String)
    case displayReconfigurationTimedOut

    var errorDescription: String? {
        switch self {
        case .missingDefaultPreset:
            "Automatic Switching is enabled, but Default Reference Mode is not set or is unavailable."
        case let .unavailablePreset(name, uniqueID):
            "Automatic Switching cannot use \(name) because it is not available on the current display. Preset ID: \(uniqueID)"
        case .displayReconfigurationTimedOut:
            "Automatic switching was cancelled because the display did not finish reconfiguring safely."
        }
    }
}

@MainActor
final class ReferenceModeRuleEngine {
    typealias UptimeProvider = () -> TimeInterval

    private struct PendingRequest: Equatable {
        let application: ActiveApplicationInfo
        let targetID: String
        let coldLaunchUptime: TimeInterval?
    }

    private struct LaunchRecord: Equatable {
        let bundleIdentifier: String
        let uptime: TimeInterval
    }

    static let geforceNOWBundleIdentifier: String = "com.nvidia.gfnpc.mall"

    private let displayPresetService: any DisplayPresetServicing
    private let ownBundleIdentifier: String?
    private let policy: ReferenceModeSafetyPolicy
    private let uptime: UptimeProvider
    private let switchDelayRange: ClosedRange<TimeInterval>

    private var pendingTask: Task<Void, Never>?
    private var pendingRequest: PendingRequest?
    private var launchedApplicationsByPID: [pid_t: LaunchRecord] = [:]
    private var lastExternalApplicationInfo: ActiveApplicationInfo?
    private var lastSwitchUptime: TimeInterval?
    private var lastDisplayChangeUptime: TimeInterval?
    private var lastSystemEventUptime: TimeInterval?
    private var displayConfigurationBeganUptime: TimeInterval?
    private var isApplyingPreset = false
    private(set) var isPaused = false

    convenience init() {
        self.init(
            displayPresetService: DisplayPresetService(),
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    init(
        displayPresetService: any DisplayPresetServicing,
        ownBundleIdentifier: String?,
        policy: ReferenceModeSafetyPolicy? = nil,
        switchDelayRange: ClosedRange<TimeInterval> = 4...4,
        uptime: @escaping UptimeProvider = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.displayPresetService = displayPresetService
        self.ownBundleIdentifier = ownBundleIdentifier
        self.policy = policy ?? .standard
        self.switchDelayRange = switchDelayRange
        self.uptime = uptime
    }

    deinit {
        pendingTask?.cancel()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            cancelPendingSwitch(reason: "automation paused")
        }
    }

    func recordLaunch(_ application: ActiveApplicationInfo, settings: XDRSwitcherSettings) {
        guard let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier == Self.geforceNOWBundleIdentifier,
              settings.appRules.contains(where: { $0.enabled && $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }
        launchedApplicationsByPID[application.processIdentifier] = LaunchRecord(
            bundleIdentifier: bundleIdentifier,
            uptime: uptime()
        )
        print("[XDRSwitcher] Cold launch detected: \(application.displayName), pid=\(application.processIdentifier)")
    }

    func recordTermination(_ application: ActiveApplicationInfo) {
        launchedApplicationsByPID.removeValue(forKey: application.processIdentifier)
        if pendingRequest?.application.processIdentifier == application.processIdentifier {
            cancelPendingSwitch(reason: "scheduled application terminated")
        }
    }

    func displayReconfigurationBegan(
        onStatusChange: @escaping @MainActor (ReferenceModeAutomationStatus, Int?) -> Void
    ) {
        displayConfigurationBeganUptime = uptime()
        cancelPendingSwitch(reason: "display reconfiguration began")
        onStatusChange(.waitingForDisplayStabilization, Int(ceil(policy.displayReconfigurationTimeout)))
        print("[XDRSwitcher] Display reconfiguration began")
    }

    func displayReconfigurationEnded() {
        displayConfigurationBeganUptime = nil
        lastDisplayChangeUptime = uptime()
        print("[XDRSwitcher] Display reconfiguration ended; stabilization period started: \(policy.displayStableDelay)s")
    }

    func systemDidWake() {
        lastSystemEventUptime = uptime()
        cancelPendingSwitch(reason: "system wake")
    }

    func cancelPendingSwitch(reason: String = "explicit cancellation") {
        if pendingTask != nil {
            print("[XDRSwitcher] Pending Task cancelled: \(reason)")
        }
        pendingTask?.cancel()
        pendingTask = nil
        pendingRequest = nil
    }

    func handleActiveApplicationChange(
        _ application: ActiveApplicationInfo,
        settings: XDRSwitcherSettings,
        currentReferencePresetID: String?,
        availableReferencePresets: [ReferencePreset],
        currentFrontmostApplication: @escaping @MainActor () -> ActiveApplicationInfo?,
        currentSettings: @escaping @MainActor () -> XDRSwitcherSettings,
        currentPresets: @escaping @MainActor () -> [ReferencePreset],
        currentPresetID: @escaping @MainActor () -> String?,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onStatusChange: @escaping @MainActor (ReferenceModeAutomationStatus, Int?) -> Void,
        onTargetChange: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard application.bundleIdentifier != ownBundleIdentifier else { return }
        if application.bundleIdentifier != nil {
            lastExternalApplicationInfo = application
        }
        evaluate(
            application: application,
            settings: settings,
            currentReferencePresetID: currentReferencePresetID,
            availableReferencePresets: availableReferencePresets,
            currentFrontmostApplication: currentFrontmostApplication,
            currentSettings: currentSettings,
            currentPresets: currentPresets,
            currentPresetID: currentPresetID,
            onPendingChange: onPendingChange,
            onStatusChange: onStatusChange,
            onTargetChange: onTargetChange,
            onError: onError,
            onApplied: onApplied
        )
    }

    func reevaluate(
        settings: XDRSwitcherSettings,
        currentReferencePresetID: String?,
        availableReferencePresets: [ReferencePreset],
        currentFrontmostApplication: @escaping @MainActor () -> ActiveApplicationInfo?,
        currentSettings: @escaping @MainActor () -> XDRSwitcherSettings,
        currentPresets: @escaping @MainActor () -> [ReferencePreset],
        currentPresetID: @escaping @MainActor () -> String?,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onStatusChange: @escaping @MainActor (ReferenceModeAutomationStatus, Int?) -> Void,
        onTargetChange: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard let frontmost = currentFrontmostApplication() else {
            cancelPendingSwitch(reason: "frontmost application unavailable")
            onPendingChange(false)
            return
        }
        let application = frontmost.bundleIdentifier == ownBundleIdentifier ? lastExternalApplicationInfo : frontmost
        guard let application else { return }
        handleActiveApplicationChange(
            application,
            settings: settings,
            currentReferencePresetID: currentReferencePresetID,
            availableReferencePresets: availableReferencePresets,
            currentFrontmostApplication: currentFrontmostApplication,
            currentSettings: currentSettings,
            currentPresets: currentPresets,
            currentPresetID: currentPresetID,
            onPendingChange: onPendingChange,
            onStatusChange: onStatusChange,
            onTargetChange: onTargetChange,
            onError: onError,
            onApplied: onApplied
        )
    }

    static func targetPreset(
        for bundleIdentifier: String?,
        settings: XDRSwitcherSettings,
        availableReferencePresets: [ReferencePreset] = []
    ) throws -> ReferenceModeRuleTarget? {
        guard settings.automaticSwitchingEnabled, let bundleIdentifier else { return nil }

        if let rule = settings.appRules.first(where: { $0.enabled && $0.bundleIdentifier == bundleIdentifier }) {
            let target = ReferenceModeRuleTarget(
                uniqueID: rule.presetUniqueID,
                name: rule.presetName,
                source: .appRule(bundleIdentifier: bundleIdentifier)
            )
            try validate(target, availableReferencePresets: availableReferencePresets)
            return target
        }

        guard let uniqueID = settings.defaultPresetUniqueID, let name = settings.defaultPresetName else {
            throw ReferenceModeRuleEngineError.missingDefaultPreset
        }
        let target = ReferenceModeRuleTarget(uniqueID: uniqueID, name: name, source: .defaultPreset)
        try validate(target, availableReferencePresets: availableReferencePresets)
        return target
    }

    private func evaluate(
        application: ActiveApplicationInfo,
        settings: XDRSwitcherSettings,
        currentReferencePresetID: String?,
        availableReferencePresets: [ReferencePreset],
        currentFrontmostApplication: @escaping @MainActor () -> ActiveApplicationInfo?,
        currentSettings: @escaping @MainActor () -> XDRSwitcherSettings,
        currentPresets: @escaping @MainActor () -> [ReferencePreset],
        currentPresetID: @escaping @MainActor () -> String?,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onStatusChange: @escaping @MainActor (ReferenceModeAutomationStatus, Int?) -> Void,
        onTargetChange: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard settings.automaticSwitchingEnabled, !isPaused else {
            cancelPendingSwitch(reason: "automatic switching disabled or paused")
            onPendingChange(false)
            onStatusChange(.paused, nil)
            onTargetChange("Not Available")
            return
        }

        guard displayConfigurationBeganUptime == nil else {
            cancelPendingSwitch(reason: "display reconfiguration in progress")
            onPendingChange(false)
            onStatusChange(.waitingForDisplayStabilization, nil)
            print("[XDRSwitcher] Switch skipped: display reconfiguration in progress")
            return
        }

        do {
            guard let target = try Self.targetPreset(
                for: application.bundleIdentifier,
                settings: settings,
                availableReferencePresets: availableReferencePresets
            ) else { return }

            onTargetChange(target.name)
            if currentReferencePresetID == target.uniqueID {
                cancelPendingSwitch(reason: "target preset already active")
                onPendingChange(false)
                onStatusChange(.ready, nil)
                onError(nil)
                return
            }

            if pendingRequest?.application == application, pendingRequest?.targetID == target.uniqueID {
                return
            }
            let request = PendingRequest(
                application: application,
                targetID: target.uniqueID,
                coldLaunchUptime: consumeColdLaunchUptime(for: application)
            )
            cancelPendingSwitch(reason: "new active application event")
            schedule(
                request: request,
                debounce: min(max(settings.switchDelaySeconds, switchDelayRange.lowerBound), switchDelayRange.upperBound),
                currentFrontmostApplication: currentFrontmostApplication,
                currentSettings: currentSettings,
                currentPresets: currentPresets,
                currentPresetID: currentPresetID,
                onPendingChange: onPendingChange,
                onStatusChange: onStatusChange,
                onTargetChange: onTargetChange,
                onError: onError,
                onApplied: onApplied
            )
        } catch {
            cancelPendingSwitch(reason: "target preset validation failed")
            onPendingChange(false)
            onTargetChange("Not Available")
            onError(error.localizedDescription)
        }
    }

    private func schedule(
        request: PendingRequest,
        debounce: TimeInterval,
        currentFrontmostApplication: @escaping @MainActor () -> ActiveApplicationInfo?,
        currentSettings: @escaping @MainActor () -> XDRSwitcherSettings,
        currentPresets: @escaping @MainActor () -> [ReferencePreset],
        currentPresetID: @escaping @MainActor () -> String?,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onStatusChange: @escaping @MainActor (ReferenceModeAutomationStatus, Int?) -> Void,
        onTargetChange: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard request.application.bundleIdentifier != nil else { return }

        let now = uptime()
        let coldLaunchUptime = request.coldLaunchUptime
        let delay: TimeInterval
        let status: ReferenceModeAutomationStatus

        let decision = waitingDecision(now: now, launchUptime: coldLaunchUptime, debounce: debounce)
        if isApplyingPreset {
            delay = max(decision.delay, policy.verificationFallbackDelay + policy.postSwitchCooldown)
            status = .coolingDown
        } else {
            delay = decision.delay
            status = decision.status
        }

        pendingRequest = request
        onPendingChange(true)
        onStatusChange(status, Self.countdownSeconds(for: status, delay: delay))
        logWaitingDecision(
            application: request.application,
            targetID: request.targetID,
            now: now,
            debounce: debounce,
            launchUptime: coldLaunchUptime,
            effectiveDelay: delay,
            status: status
        )

        pendingTask = Task { [weak self] in
            do {
                var remainingDelay = delay
                while remainingDelay > 0 {
                    let interval = min(1, remainingDelay)
                    try await Task.sleep(for: .seconds(interval))
                    try Task.checkCancellation()
                    remainingDelay = max(0, remainingDelay - interval)
                    if remainingDelay > 0,
                       let seconds = Self.countdownSeconds(for: status, delay: remainingDelay) {
                        onStatusChange(status, seconds)
                    }
                }
            } catch {
                return
            }
            guard let self, self.pendingRequest == request else { return }
            guard !Task.isCancelled else { return }

            if self.displayConfigurationBeganUptime != nil {
                self.pendingTask = nil
                self.pendingRequest = nil
                onPendingChange(false)
                onError(ReferenceModeRuleEngineError.displayReconfigurationTimedOut.localizedDescription)
                return
            }

            let frontmost = currentFrontmostApplication()
            let confirmed = frontmost?.bundleIdentifier == self.ownBundleIdentifier ? self.lastExternalApplicationInfo : frontmost
            guard confirmed?.bundleIdentifier == request.application.bundleIdentifier,
                  confirmed?.processIdentifier == request.application.processIdentifier else {
                self.cancelPendingSwitch(reason: "frontmost application or PID changed")
                onPendingChange(false)
                return
            }

            let latestSettings = currentSettings()
            guard latestSettings.automaticSwitchingEnabled, !self.isPaused else {
                self.cancelPendingSwitch(reason: "automatic switching disabled before execution")
                onPendingChange(false)
                onStatusChange(.paused, nil)
                return
            }

            do {
                guard let latestTarget = try Self.targetPreset(
                    for: confirmed?.bundleIdentifier,
                    settings: latestSettings,
                    availableReferencePresets: currentPresets()
                ), latestTarget.uniqueID == request.targetID else {
                    self.cancelPendingSwitch(reason: "target changed before execution")
                    onPendingChange(false)
                    return
                }

                if currentPresetID() == latestTarget.uniqueID {
                    self.cancelPendingSwitch(reason: "target preset became active")
                    onPendingChange(false)
                    onStatusChange(.ready, nil)
                    return
                }

                guard !self.isApplyingPreset else {
                    self.pendingTask = nil
                    print("[XDRSwitcher] Switch deferred: another Reference Mode change is running")
                    self.schedule(
                        request: request,
                        debounce: 0,
                        currentFrontmostApplication: currentFrontmostApplication,
                        currentSettings: currentSettings,
                        currentPresets: currentPresets,
                        currentPresetID: currentPresetID,
                        onPendingChange: onPendingChange,
                        onStatusChange: onStatusChange,
                        onTargetChange: onTargetChange,
                        onError: onError,
                        onApplied: onApplied
                    )
                    return
                }
                guard !Task.isCancelled else { return }
                self.pendingTask = nil
                self.pendingRequest = nil
                self.isApplyingPreset = true
                onPendingChange(false)
                onStatusChange(.switching, nil)
                onTargetChange(latestTarget.name)
                onError(nil)
                print("[XDRSwitcher] Revalidation succeeded")
                print("[XDRSwitcher] Applying preset: \(latestTarget.name)")
                print("[XDRSwitcher] CoreDisplay call: yes")

                do {
                    let snapshot = try await self.displayPresetService.applyPresetForAutomaticSwitch(uniqueID: latestTarget.uniqueID)
                    self.lastSwitchUptime = self.uptime()
                    self.isApplyingPreset = false
                    onApplied(snapshot)
                    onStatusChange(.coolingDown, nil)
                    print("[XDRSwitcher] Cooldown started: \(self.policy.postSwitchCooldown) seconds")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(self?.policy.postSwitchCooldown ?? 0))
                        guard let self else { return }
                        print("[XDRSwitcher] Cooldown ended")
                        if self.pendingTask == nil {
                            onStatusChange(.ready, nil)
                        }
                    }
                } catch is CancellationError {
                    self.isApplyingPreset = false
                    print("[XDRSwitcher] Switch skipped: task cancelled")
                } catch {
                    self.isApplyingPreset = false
                    onError(error.localizedDescription)
                    onStatusChange(.ready, nil)
                    print("[XDRSwitcher] CoreDisplay call failed: \(error.localizedDescription)")
                }
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func waitingDecision(
        now: TimeInterval,
        launchUptime: TimeInterval?,
        debounce: TimeInterval
    ) -> (delay: TimeInterval, status: ReferenceModeAutomationStatus) {
        var decision = (delay: max(0, debounce), status: ReferenceModeAutomationStatus.ready)

        func consider(_ delay: TimeInterval, status: ReferenceModeAutomationStatus) {
            let remaining = max(0, delay)
            if remaining > decision.delay {
                decision = (remaining, status)
            }
        }

        consider(policy.bootGracePeriod - now, status: .waitingForSystemStartup)
        if let launchUptime {
            consider(policy.coldLaunchDelay - (now - launchUptime), status: .waitingForApplicationInitialization)
        }
        if let lastSwitchUptime {
            consider(policy.postSwitchCooldown - (now - lastSwitchUptime), status: .coolingDown)
        }
        if let lastDisplayChangeUptime {
            consider(policy.displayStableDelay - (now - lastDisplayChangeUptime), status: .waitingForDisplayStabilization)
        }
        if let lastSystemEventUptime {
            consider(policy.systemEventGracePeriod - (now - lastSystemEventUptime), status: .waitingForDisplayStabilization)
        }
        return decision
    }

    private func consumeColdLaunchUptime(for application: ActiveApplicationInfo) -> TimeInterval? {
        guard application.bundleIdentifier == Self.geforceNOWBundleIdentifier,
              let bundleIdentifier = application.bundleIdentifier,
              let record = launchedApplicationsByPID[application.processIdentifier],
              record.bundleIdentifier == bundleIdentifier else {
            return nil
        }
        launchedApplicationsByPID.removeValue(forKey: application.processIdentifier)
        return record.uptime
    }

    private func logWaitingDecision(
        application: ActiveApplicationInfo,
        targetID: String,
        now: TimeInterval,
        debounce: TimeInterval,
        launchUptime: TimeInterval?,
        effectiveDelay: TimeInterval,
        status: ReferenceModeAutomationStatus
    ) {
        let debounceEnd = now + debounce
        let bootEnd = policy.bootGracePeriod
        let coldLaunchEnd = launchUptime.map { $0 + policy.coldLaunchDelay }
        let wakeEnd = lastSystemEventUptime.map { $0 + policy.systemEventGracePeriod }
        let displayEnd = lastDisplayChangeUptime.map { $0 + policy.displayStableDelay }
        let cooldownEnd = lastSwitchUptime.map { $0 + policy.postSwitchCooldown }
        let bundleIdentifier = application.bundleIdentifier ?? "Not Available"
        let coldLaunchDeadline = coldLaunchEnd.map { String($0) } ?? "none"
        let wakeDeadline = wakeEnd.map { String($0) } ?? "none"
        let displayDeadline = displayEnd.map { String($0) } ?? "none"
        let cooldownDeadline = cooldownEnd.map { String($0) } ?? "none"
        print(
            "[XDRSwitcher] Active app: \(application.displayName), bundleIdentifier=\(bundleIdentifier), " +
            "pid=\(application.processIdentifier), coldLaunch=\(launchUptime != nil), target=\(targetID)"
        )
        if launchUptime != nil {
            print("[XDRSwitcher] Waiting \(policy.coldLaunchDelay) seconds for GPU initialization")
        }
        print(
            "[XDRSwitcher] Protection deadlines: debounce=\(debounceEnd), boot=\(bootEnd), " +
            "coldLaunch=\(coldLaunchDeadline), wake=\(wakeDeadline), " +
            "display=\(displayDeadline), cooldown=\(cooldownDeadline)"
        )
        print("[XDRSwitcher] Effective wait reason: \(status), scheduledUptime=\(now + effectiveDelay)")
    }

    private static func countdownSeconds(
        for status: ReferenceModeAutomationStatus,
        delay: TimeInterval
    ) -> Int? {
        switch status {
        case .waitingForSystemStartup, .waitingForApplicationInitialization, .waitingForDisplayStabilization:
            return Int(ceil(max(0, delay)))
        case .coolingDown, .ready, .switching, .paused:
            return nil
        }
    }

    private func log(
        _ application: ActiveApplicationInfo,
        coldLaunch: Bool,
        target: String?,
        message: String
    ) {
        print(
            "XDRSwitcher automation uptime=\(uptime()) app=\(application.displayName) " +
            "bundleIdentifier=\(application.bundleIdentifier ?? "Not Available") " +
            "pid=\(application.processIdentifier) coldLaunch=\(coldLaunch) " +
            "target=\(target ?? "Not Available") \(message)"
        )
    }

    private static func validate(
        _ target: ReferenceModeRuleTarget,
        availableReferencePresets: [ReferencePreset]
    ) throws {
        guard !availableReferencePresets.isEmpty else { return }
        guard availableReferencePresets.contains(where: { $0.uniqueID == target.uniqueID && $0.isValid }) else {
            throw ReferenceModeRuleEngineError.unavailablePreset(name: target.name, uniqueID: target.uniqueID)
        }
    }
}
