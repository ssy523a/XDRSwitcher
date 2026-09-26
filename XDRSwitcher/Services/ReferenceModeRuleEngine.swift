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
    }

    private let displayPresetService: any DisplayPresetServicing
    private let ownBundleIdentifier: String?
    private let policy: ReferenceModeSafetyPolicy
    private let uptime: UptimeProvider

    private var pendingTask: Task<Void, Never>?
    private var pendingRequest: PendingRequest?
    private var launchedAtByPID: [pid_t: TimeInterval] = [:]
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
        uptime: @escaping UptimeProvider = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.displayPresetService = displayPresetService
        self.ownBundleIdentifier = ownBundleIdentifier
        self.policy = policy ?? .standard
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
              settings.appRules.contains(where: { $0.enabled && $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }
        launchedAtByPID[application.processIdentifier] = uptime()
        log(application, coldLaunch: true, target: nil, message: "launch recorded")
    }

    func recordTermination(_ application: ActiveApplicationInfo) {
        launchedAtByPID.removeValue(forKey: application.processIdentifier)
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
        print("XDRSwitcher display reconfiguration begin")
    }

    func displayReconfigurationEnded() {
        displayConfigurationBeganUptime = nil
        lastDisplayChangeUptime = uptime()
        lastSystemEventUptime = uptime()
        print("XDRSwitcher display reconfiguration end")
    }

    func systemDidWake() {
        lastSystemEventUptime = uptime()
        cancelPendingSwitch(reason: "system wake")
    }

    func cancelPendingSwitch(reason: String = "explicit cancellation") {
        if pendingTask != nil {
            print("XDRSwitcher pending switch cancelled reason=\(reason)")
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

            let request = PendingRequest(application: application, targetID: target.uniqueID)
            if request == pendingRequest { return }
            cancelPendingSwitch(reason: "new active application event")
            schedule(
                request: request,
                debounce: settings.switchDelaySeconds,
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
        let coldLaunchUptime = launchedAtByPID[request.application.processIdentifier]
        let delay: TimeInterval
        let status: ReferenceModeAutomationStatus

        if let began = displayConfigurationBeganUptime {
            let elapsed = now - began
            if elapsed >= policy.displayReconfigurationTimeout {
                onError(ReferenceModeRuleEngineError.displayReconfigurationTimedOut.localizedDescription)
                onStatusChange(.waitingForDisplayStabilization, 0)
                return
            }
            delay = policy.displayReconfigurationTimeout - elapsed
            status = .waitingForDisplayStabilization
        } else {
            let decision = waitingDecision(now: now, launchUptime: coldLaunchUptime, debounce: debounce)
            if isApplyingPreset {
                delay = max(decision.delay, policy.verificationFallbackDelay + policy.postSwitchCooldown)
                status = .coolingDown
            } else {
                delay = decision.delay
                status = decision.status
            }
        }

        pendingRequest = request
        onPendingChange(true)
        onStatusChange(status, Self.countdownSeconds(for: status, delay: delay))
        log(request.application, coldLaunch: coldLaunchUptime != nil, target: request.targetID, message: "wait=\(delay)s reason=\(status.rawValue)")

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

                guard !self.isApplyingPreset else { return }
                self.pendingTask = nil
                self.pendingRequest = nil
                self.isApplyingPreset = true
                onPendingChange(false)
                onStatusChange(.switching, nil)
                onTargetChange(latestTarget.name)
                onError(nil)
                self.log(request.application, coldLaunch: coldLaunchUptime != nil, target: latestTarget.name, message: "switching")

                do {
                    let snapshot = try await self.displayPresetService.applyPresetForAutomaticSwitch(uniqueID: latestTarget.uniqueID)
                    self.lastSwitchUptime = self.uptime()
                    self.isApplyingPreset = false
                    onApplied(snapshot)
                    onStatusChange(.coolingDown, nil)
                    print("XDRSwitcher cooldown start duration=\(self.policy.postSwitchCooldown)s")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(self?.policy.postSwitchCooldown ?? 0))
                        guard let self else { return }
                        print("XDRSwitcher cooldown end")
                        if self.pendingTask == nil {
                            onStatusChange(.ready, nil)
                        }
                    }
                } catch is CancellationError {
                    self.isApplyingPreset = false
                } catch {
                    self.isApplyingPreset = false
                    onError(error.localizedDescription)
                    onStatusChange(.ready, nil)
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
