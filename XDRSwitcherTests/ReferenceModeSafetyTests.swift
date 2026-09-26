import CoreGraphics
import Foundation
import Testing
@testable import XDRSwitcher

private final class MockDisplayPresetService: DisplayPresetServicing {
    var applyCount = 0
    var appliedIDs: [String] = []
    var shouldFail = false

    let defaultPreset = ReferencePreset(runtimeIndex: 0, name: "Default", uniqueID: "default", isValid: true)
    let rulePreset = ReferencePreset(runtimeIndex: 1, name: "Rule", uniqueID: "rule", isValid: true)

    func loadBuiltInDisplayPresets() throws -> DisplayPresetSnapshot {
        DisplayPresetSnapshot(displayID: 1, presets: [defaultPreset, rulePreset], activePreset: defaultPreset)
    }

    func applyPreset(uniqueID: String) throws -> DisplayPresetSnapshot {
        try result(uniqueID: uniqueID)
    }

    func applyPresetForAutomaticSwitch(uniqueID: String) async throws -> DisplayPresetSnapshot {
        applyCount += 1
        appliedIDs.append(uniqueID)
        if shouldFail {
            throw CoreDisplayError.presetSwitchFailed(index: 1, status: -1)
        }
        return try result(uniqueID: uniqueID)
    }

    private func result(uniqueID: String) throws -> DisplayPresetSnapshot {
        let presets = [defaultPreset, rulePreset]
        guard let preset = presets.first(where: { $0.uniqueID == uniqueID }) else {
            throw CoreDisplayError.presetNotFound(uniqueID: uniqueID)
        }
        return DisplayPresetSnapshot(displayID: 1, presets: presets, activePreset: preset)
    }
}

@MainActor
private final class AutomationHarness {
    let service = MockDisplayPresetService()
    var now: TimeInterval
    var settings: XDRSwitcherSettings
    var presets: [ReferencePreset]
    var currentID: String?
    var frontmost: ActiveApplicationInfo?
    var status = ReferenceModeAutomationStatus.ready
    var statusRemainingSeconds: Int?
    var error: String?
    var pending = false
    var appliedCount = 0
    let engine: ReferenceModeRuleEngine

    init(now: TimeInterval = 1_000, policy: ReferenceModeSafetyPolicy? = nil) {
        self.now = now
        settings = .test
        presets = [service.defaultPreset, service.rulePreset]
        currentID = service.defaultPreset.uniqueID
        frontmost = .rule
        engine = ReferenceModeRuleEngine(
            displayPresetService: service,
            ownBundleIdentifier: "com.example.XDRSwitcher",
            policy: policy ?? .test,
            uptime: { now }
        )
    }

    func activate(_ application: ActiveApplicationInfo) {
        frontmost = application
        engine.handleActiveApplicationChange(
            application,
            settings: settings,
            currentReferencePresetID: currentID,
            availableReferencePresets: presets,
            currentFrontmostApplication: { self.frontmost },
            currentSettings: { self.settings },
            currentPresets: { self.presets },
            currentPresetID: { self.currentID },
            onPendingChange: { self.pending = $0 },
            onStatusChange: { status, remainingSeconds in
                self.status = status
                self.statusRemainingSeconds = remainingSeconds
            },
            onTargetChange: { _ in },
            onError: { self.error = $0 },
            onApplied: {
                self.currentID = $0.activePreset?.uniqueID
                self.appliedCount += 1
            }
        )
    }

    func reevaluate() {
        engine.reevaluate(
            settings: settings,
            currentReferencePresetID: currentID,
            availableReferencePresets: presets,
            currentFrontmostApplication: { self.frontmost },
            currentSettings: { self.settings },
            currentPresets: { self.presets },
            currentPresetID: { self.currentID },
            onPendingChange: { self.pending = $0 },
            onStatusChange: { status, remainingSeconds in
                self.status = status
                self.statusRemainingSeconds = remainingSeconds
            },
            onTargetChange: { _ in },
            onError: { self.error = $0 },
            onApplied: {
                self.currentID = $0.activePreset?.uniqueID
                self.appliedCount += 1
            }
        )
    }
}

private extension ReferenceModeSafetyPolicy {
    static let test = ReferenceModeSafetyPolicy(
        bootGracePeriod: 0,
        coldLaunchDelay: 0.03,
        postSwitchCooldown: 0.03,
        displayStableDelay: 0.03,
        systemEventGracePeriod: 0.03,
        verificationFallbackDelay: 0,
        displayReconfigurationTimeout: 0.03
    )
}

private extension XDRSwitcherSettings {
    static let test = XDRSwitcherSettings(
        automaticSwitchingEnabled: true,
        defaultPresetUniqueID: "default",
        defaultPresetName: "Default",
        appRules: [
            AppRule(
                appDisplayName: "Rule App",
                bundleIdentifier: "com.example.rule",
                appPath: nil,
                presetUniqueID: "rule",
                presetName: "Rule"
            )
        ],
        switchDelaySeconds: 0.01,
        launchAtLoginEnabled: false
    )
}

private extension ActiveApplicationInfo {
    static let rule = ActiveApplicationInfo(
        localizedName: "Rule App",
        bundleIdentifier: "com.example.rule",
        bundleURL: nil,
        processIdentifier: 101
    )
    static let other = ActiveApplicationInfo(
        localizedName: "Other App",
        bundleIdentifier: "com.example.other",
        bundleURL: nil,
        processIdentifier: 202
    )
    static let own = ActiveApplicationInfo(
        localizedName: "XDRSwitcher",
        bundleIdentifier: "com.example.XDRSwitcher",
        bundleURL: nil,
        processIdentifier: 303
    )
}

private func wait(_ duration: TimeInterval = 0.06) async {
    try? await Task.sleep(for: .seconds(duration))
}

@Suite("Reference Mode automatic-switch safety")
@MainActor
struct ReferenceModeSafetyTests {
    @Test("Boot uptime below 120 seconds is held")
    func bootGracePeriodHolds() {
        let delay = ReferenceModeSafetyPolicy.standard.requiredDelay(
            debounce: 0.7,
            systemUptime: 71,
            launchUptime: nil,
            lastSwitchUptime: nil,
            lastDisplayChangeUptime: nil,
            systemEventUptime: nil
        )
        #expect(delay == 49)
        #expect(ReferenceModeSafetyPolicy.standard.bootGraceRemainingSeconds(systemUptime: 71.1) == 49)
    }

    @Test("Boot uptime after 120 seconds allows normal debounce")
    func bootGracePeriodEnds() {
        let delay = ReferenceModeSafetyPolicy.standard.requiredDelay(
            debounce: 0.7,
            systemUptime: 121,
            launchUptime: nil,
            lastSwitchUptime: nil,
            lastDisplayChangeUptime: nil,
            systemEventUptime: nil
        )
        #expect(delay == 0.7)
    }

    @Test("New rule app is held for cold-launch delay")
    func coldLaunchDelay() {
        let delay = ReferenceModeSafetyPolicy.standard.requiredDelay(
            debounce: 0.7,
            systemUptime: 125,
            launchUptime: 123,
            lastSwitchUptime: nil,
            lastDisplayChangeUptime: nil,
            systemEventUptime: nil
        )
        #expect(delay == 8)
    }

    @Test("Changing app during cold launch cancels request")
    func coldLaunchAppChange() async {
        let harness = AutomationHarness()
        harness.engine.recordLaunch(.rule, settings: harness.settings)
        harness.activate(.rule)
        harness.activate(.other)
        await wait()
        #expect(!harness.service.appliedIDs.contains("rule"))
    }

    @Test("Changing PID during cold launch cancels request")
    func coldLaunchPIDChange() async {
        let harness = AutomationHarness()
        harness.engine.recordLaunch(.rule, settings: harness.settings)
        harness.activate(.rule)
        #expect(harness.status == .waitingForApplicationInitialization)
        #expect(harness.statusRemainingSeconds == 1)
        harness.frontmost = ActiveApplicationInfo(
            localizedName: "Rule App",
            bundleIdentifier: "com.example.rule",
            bundleURL: nil,
            processIdentifier: 999
        )
        await wait()
        #expect(harness.service.applyCount == 0)
    }

    @Test("Rapid activation cancels previous task")
    func rapidSwitchCancellation() async {
        let harness = AutomationHarness()
        harness.activate(.rule)
        harness.activate(.other)
        await wait()
        #expect(!harness.service.appliedIDs.contains("rule"))
    }

    @Test("Automatic switching off prevents calls")
    func automaticOff() async {
        let harness = AutomationHarness()
        harness.settings.automaticSwitchingEnabled = false
        harness.activate(.rule)
        await wait()
        #expect(harness.service.applyCount == 0)
        #expect(harness.status == .paused)
    }

    @Test("Pause prevents calls")
    func paused() async {
        let harness = AutomationHarness()
        harness.engine.setPaused(true)
        harness.activate(.rule)
        await wait()
        #expect(harness.service.applyCount == 0)
    }

    @Test("Already active preset is not applied")
    func duplicatePreset() async {
        let harness = AutomationHarness()
        harness.currentID = "rule"
        harness.activate(.rule)
        await wait()
        #expect(harness.service.applyCount == 0)
    }

    @Test("Display reconfiguration blocks a switch")
    func displayReconfigurationBlocks() async {
        let harness = AutomationHarness()
        harness.engine.displayReconfigurationBegan { status, _ in harness.status = status }
        harness.activate(.rule)
        await wait()
        #expect(harness.service.applyCount == 0)
        #expect(harness.error != nil)
    }

    @Test("Display stabilization delay is applied")
    func displayStableDelay() async {
        let harness = AutomationHarness()
        harness.engine.displayReconfigurationBegan { status, _ in harness.status = status }
        harness.engine.displayReconfigurationEnded()
        harness.activate(.rule)
        #expect(harness.status == .waitingForDisplayStabilization)
        #expect(harness.statusRemainingSeconds == 1)
        await wait(0.015)
        #expect(harness.service.applyCount == 0)
        await wait()
        #expect(harness.service.applyCount == 1)
    }

    @Test("Cooldown coalesces duplicate requests")
    func cooldownCoalesces() async {
        let harness = AutomationHarness()
        harness.activate(.rule)
        await wait(0.02)
        harness.currentID = "default"
        harness.activate(.rule)
        harness.activate(.rule)
        await wait()
        #expect(harness.service.applyCount <= 2)
    }

    @Test("Wake grace period blocks immediate switch")
    func wakeGracePeriod() async {
        let harness = AutomationHarness()
        harness.engine.systemDidWake()
        harness.activate(.rule)
        await wait(0.015)
        #expect(harness.service.applyCount == 0)
        await wait()
        #expect(harness.service.applyCount == 1)
    }

    @Test("Missing preset reports an error without applying")
    func missingPreset() async {
        let harness = AutomationHarness()
        harness.presets = [harness.service.defaultPreset]
        harness.activate(.rule)
        await wait()
        #expect(harness.service.applyCount == 0)
        #expect(harness.error != nil)
    }

    @Test("Own-app activation preserves external target")
    func ownAppException() async {
        let harness = AutomationHarness()
        harness.frontmost = .rule
        harness.activate(.rule)
        harness.frontmost = .own
        harness.reevaluate()
        await wait()
        #expect(harness.service.applyCount == 1)
    }

    @Test("A failed switch is not retried")
    func noInfiniteRetry() async {
        let harness = AutomationHarness()
        harness.service.shouldFail = true
        harness.activate(.rule)
        await wait(0.12)
        #expect(harness.service.applyCount == 1)
        #expect(harness.error != nil)
    }
}
