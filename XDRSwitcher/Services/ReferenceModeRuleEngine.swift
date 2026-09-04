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
            return "Automatic Switching is enabled, but Default Reference Mode is not set or is unavailable."
        case let .unavailablePreset(name, uniqueID):
            return "Automatic Switching cannot use \(name) because it is not available on the current display. Preset ID: \(uniqueID)"
        }
    }
}

@MainActor
final class ReferenceModeRuleEngine {
    private let displayPresetService: any DisplayPresetServicing
    private let ownBundleIdentifier: String?
    private var pendingTask: Task<Void, Never>?
    private var isApplyingPreset = false
    private var lastExternalApplicationInfo: ActiveApplicationInfo?
    private var lastReportedError: String?

    convenience init() {
        self.init(
            displayPresetService: DisplayPresetService(),
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    init(displayPresetService: any DisplayPresetServicing, ownBundleIdentifier: String?) {
        self.displayPresetService = displayPresetService
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    deinit {
        pendingTask?.cancel()
    }

    func handleActiveApplicationChange(
        _ activeApplicationInfo: ActiveApplicationInfo,
        settings: XDRSwitcherSettings,
        currentReferencePresetID: String?,
        availableReferencePresets: [ReferencePreset],
        currentFrontmostApplication: @escaping @MainActor () -> ActiveApplicationInfo?,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onTargetChange: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard activeApplicationInfo.bundleIdentifier != ownBundleIdentifier else {
            return
        }

        if activeApplicationInfo.bundleIdentifier != nil {
            lastExternalApplicationInfo = activeApplicationInfo
        }

        evaluate(
            activeApplicationInfo: activeApplicationInfo,
            settings: settings,
            currentReferencePresetID: currentReferencePresetID,
            availableReferencePresets: availableReferencePresets,
            currentFrontmostApplication: currentFrontmostApplication,
            onPendingChange: onPendingChange,
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
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onTargetChange: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard let activeApplicationInfo = currentFrontmostApplication() else {
            pendingTask?.cancel()
            onPendingChange(false)
            return
        }

        if activeApplicationInfo.bundleIdentifier == ownBundleIdentifier,
           let lastExternalApplicationInfo {
            evaluate(
                activeApplicationInfo: lastExternalApplicationInfo,
                settings: settings,
                currentReferencePresetID: currentReferencePresetID,
                availableReferencePresets: availableReferencePresets,
                currentFrontmostApplication: currentFrontmostApplication,
                onPendingChange: onPendingChange,
                onTargetChange: onTargetChange,
                onError: onError,
                onApplied: onApplied
            )
            return
        }

        handleActiveApplicationChange(
            activeApplicationInfo,
            settings: settings,
            currentReferencePresetID: currentReferencePresetID,
            availableReferencePresets: availableReferencePresets,
            currentFrontmostApplication: currentFrontmostApplication,
            onPendingChange: onPendingChange,
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
        guard settings.automaticSwitchingEnabled else {
            return nil
        }

        guard let bundleIdentifier else {
            return nil
        }

        if let rule = settings.appRules.first(where: { $0.enabled && $0.bundleIdentifier == bundleIdentifier }) {
            let target = ReferenceModeRuleTarget(
                uniqueID: rule.presetUniqueID,
                name: rule.presetName,
                source: .appRule(bundleIdentifier: bundleIdentifier)
            )
            try validate(target, availableReferencePresets: availableReferencePresets)
            return target
        }

        guard let defaultPresetUniqueID = settings.defaultPresetUniqueID,
              let defaultPresetName = settings.defaultPresetName else {
            throw ReferenceModeRuleEngineError.missingDefaultPreset
        }

        let target = ReferenceModeRuleTarget(
            uniqueID: defaultPresetUniqueID,
            name: defaultPresetName,
            source: .defaultPreset
        )
        try validate(target, availableReferencePresets: availableReferencePresets)
        return target
    }

    private func evaluate(
        activeApplicationInfo: ActiveApplicationInfo,
        settings: XDRSwitcherSettings,
        currentReferencePresetID: String?,
        availableReferencePresets: [ReferencePreset],
        currentFrontmostApplication: @escaping @MainActor () -> ActiveApplicationInfo?,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onTargetChange: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        pendingTask?.cancel()

        guard settings.automaticSwitchingEnabled else {
            onPendingChange(false)
            onTargetChange("Not Available")
            onError(nil)
            lastReportedError = nil
            return
        }

        do {
            guard let target = try Self.targetPreset(
                for: activeApplicationInfo.bundleIdentifier,
                settings: settings,
                availableReferencePresets: availableReferencePresets
            ) else {
                onPendingChange(false)
                return
            }

            onTargetChange(target.name)

            if currentReferencePresetID == target.uniqueID {
                onPendingChange(false)
                onError(nil)
                lastReportedError = nil
                return
            }

            scheduleSwitch(
                target: target,
                scheduledBundleIdentifier: activeApplicationInfo.bundleIdentifier,
                delaySeconds: settings.switchDelaySeconds,
                currentFrontmostApplication: currentFrontmostApplication,
                onPendingChange: onPendingChange,
                onError: onError,
                onApplied: onApplied
            )
        } catch {
            report(error.localizedDescription, onError: onError)
            onPendingChange(false)
            onTargetChange("Not Available")
        }
    }

    private func scheduleSwitch(
        target: ReferenceModeRuleTarget,
        scheduledBundleIdentifier: String?,
        delaySeconds: Double,
        currentFrontmostApplication: @escaping @MainActor () -> ActiveApplicationInfo?,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard scheduledBundleIdentifier != nil else {
            onPendingChange(false)
            return
        }

        onPendingChange(true)

        pendingTask = Task { [weak self] in
            let nanoseconds = UInt64(max(delaySeconds, 0) * 1_000_000_000)

            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                await MainActor.run {
                    onPendingChange(false)
                }
                return
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else {
                    onPendingChange(false)
                    return
                }

                let confirmedApplicationInfo = currentFrontmostApplication()
                let confirmedBundleIdentifier = confirmedApplicationInfo?.bundleIdentifier

                if confirmedBundleIdentifier != self.ownBundleIdentifier,
                   confirmedBundleIdentifier != scheduledBundleIdentifier {
                    onPendingChange(false)
                    return
                }

                self.apply(
                    target: target,
                    onPendingChange: onPendingChange,
                    onError: onError,
                    onApplied: onApplied
                )
            }
        }
    }

    private func apply(
        target: ReferenceModeRuleTarget,
        onPendingChange: @escaping @MainActor (Bool) -> Void,
        onError: @escaping @MainActor (String?) -> Void,
        onApplied: @escaping @MainActor (DisplayPresetSnapshot) -> Void
    ) {
        guard !isApplyingPreset else {
            onPendingChange(false)
            return
        }

        isApplyingPreset = true
        defer {
            isApplyingPreset = false
            onPendingChange(false)
        }

        do {
            let snapshot = try displayPresetService.applyPreset(uniqueID: target.uniqueID)
            lastReportedError = nil
            onError(nil)
            onApplied(snapshot)
        } catch {
            report(error.localizedDescription, onError: onError)
        }
    }

    private func report(_ message: String, onError: @escaping @MainActor (String?) -> Void) {
        onError(message)

        guard lastReportedError != message else {
            return
        }

        lastReportedError = message
        print("XDRSwitcher automatic switching error: \(message)")
    }

    private static func validate(
        _ target: ReferenceModeRuleTarget,
        availableReferencePresets: [ReferencePreset]
    ) throws {
        guard !availableReferencePresets.isEmpty else {
            return
        }

        guard availableReferencePresets.contains(where: { $0.uniqueID == target.uniqueID && $0.isValid }) else {
            throw ReferenceModeRuleEngineError.unavailablePreset(name: target.name, uniqueID: target.uniqueID)
        }
    }
}
