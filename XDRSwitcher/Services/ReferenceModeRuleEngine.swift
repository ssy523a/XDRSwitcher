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

    var errorDescription: String? {
        switch self {
        case .missingDefaultPreset:
            "Automatic Switching is enabled, but Default Reference Mode is not set or is unavailable."
        case let .unavailablePreset(name, uniqueID):
            "Automatic Switching cannot use \(name) because it is not available on the current display. Preset ID: \(uniqueID)"
        }
    }
}

@MainActor
final class ReferenceModeRuleEngine {
    private struct PendingRequest: Equatable {
        let application: ActiveApplicationInfo
        let targetID: String
    }

    private let displayPresetService: any DisplayPresetServicing
    private let ownBundleIdentifier: String?
    private let switchDelayRange: ClosedRange<TimeInterval>

    private var pendingTask: Task<Void, Never>?
    private var pendingRequest: PendingRequest?
    private var lastExternalApplicationInfo: ActiveApplicationInfo?
    private var isApplyingPreset: Bool = false
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
        switchDelayRange: ClosedRange<TimeInterval> = 4...4
    ) {
        self.displayPresetService = displayPresetService
        self.ownBundleIdentifier = ownBundleIdentifier
        self.switchDelayRange = switchDelayRange
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
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard let frontmost = currentFrontmostApplication() else {
            cancelPendingSwitch(reason: "frontmost application unavailable")
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
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard settings.automaticSwitchingEnabled, !isPaused else {
            cancelPendingSwitch(reason: "automatic switching disabled or paused")
            return
        }

        do {
            guard let target = try Self.targetPreset(
                for: application.bundleIdentifier,
                settings: settings,
                availableReferencePresets: availableReferencePresets
            ) else {
                return
            }

            if currentReferencePresetID == target.uniqueID {
                cancelPendingSwitch(reason: "target preset already active")
                onError(nil)
                return
            }

            let request = PendingRequest(application: application, targetID: target.uniqueID)
            if request == pendingRequest {
                return
            }

            cancelPendingSwitch(reason: "new active application event")
            schedule(
                request: request,
                delay: min(max(settings.switchDelaySeconds, switchDelayRange.lowerBound), switchDelayRange.upperBound),
                currentFrontmostApplication: currentFrontmostApplication,
                currentSettings: currentSettings,
                currentPresets: currentPresets,
                currentPresetID: currentPresetID,
                onError: onError,
                onApplied: onApplied
            )
        } catch {
            cancelPendingSwitch(reason: "target preset validation failed")
            onError(error.localizedDescription)
        }
    }

    private func schedule(
        request: PendingRequest,
        delay: TimeInterval,
        currentFrontmostApplication: @escaping @MainActor () -> ActiveApplicationInfo?,
        currentSettings: @escaping @MainActor () -> XDRSwitcherSettings,
        currentPresets: @escaping @MainActor () -> [ReferencePreset],
        currentPresetID: @escaping @MainActor () -> String?,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard request.application.bundleIdentifier != nil else { return }

        pendingRequest = request
        print(
            "[XDRSwitcher] Scheduled switch in \(delay) seconds: app=\(request.application.displayName), " +
            "bundleIdentifier=\(request.application.bundleIdentifier ?? "Not Available"), " +
            "pid=\(request.application.processIdentifier), target=\(request.targetID)"
        )

        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
            } catch {
                return
            }

            guard let self, self.pendingRequest == request, !Task.isCancelled else { return }

            let frontmost = currentFrontmostApplication()
            let confirmed = frontmost?.bundleIdentifier == self.ownBundleIdentifier ? self.lastExternalApplicationInfo : frontmost
            guard confirmed?.bundleIdentifier == request.application.bundleIdentifier,
                  confirmed?.processIdentifier == request.application.processIdentifier else {
                self.cancelPendingSwitch(reason: "frontmost application or PID changed")
                return
            }

            let latestSettings = currentSettings()
            guard latestSettings.automaticSwitchingEnabled, !self.isPaused else {
                self.cancelPendingSwitch(reason: "automatic switching disabled before execution")
                return
            }

            do {
                guard let latestTarget = try Self.targetPreset(
                    for: confirmed?.bundleIdentifier,
                    settings: latestSettings,
                    availableReferencePresets: currentPresets()
                ), latestTarget.uniqueID == request.targetID else {
                    self.cancelPendingSwitch(reason: "target changed before execution")
                    return
                }

                if currentPresetID() == latestTarget.uniqueID {
                    self.cancelPendingSwitch(reason: "target preset became active")
                    return
                }

                guard !self.isApplyingPreset else {
                    self.cancelPendingSwitch(reason: "another Reference Mode change is running")
                    return
                }
                guard !Task.isCancelled else { return }

                self.pendingTask = nil
                self.pendingRequest = nil
                self.isApplyingPreset = true
                onError(nil)

                do {
                    print("[XDRSwitcher] Applying preset: \(latestTarget.name)")
                    let snapshot = try await self.displayPresetService.applyPresetForAutomaticSwitch(
                        uniqueID: latestTarget.uniqueID
                    )
                    self.isApplyingPreset = false
                    onApplied(snapshot)
                } catch is CancellationError {
                    self.isApplyingPreset = false
                } catch {
                    self.isApplyingPreset = false
                    onError(error.localizedDescription)
                }
            } catch {
                onError(error.localizedDescription)
            }
        }
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
