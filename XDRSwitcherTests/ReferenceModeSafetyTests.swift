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

private final class TestClock {
    var date = Date(timeIntervalSinceReferenceDate: 1_000)
    var uptime: TimeInterval = 1_000

    func advance(by interval: TimeInterval) {
        date.addTimeInterval(interval)
        uptime += interval
    }
}

@MainActor
private final class AutomationHarness {
    let service = MockDisplayPresetService()
    var settings: XDRSwitcherSettings
    var presets: [ReferencePreset]
    var currentID: String?
    var frontmost: ActiveApplicationInfo?
    var error: String?
    var appliedCount = 0
    let engine: ReferenceModeRuleEngine
    let clock: TestClock

    init() {
        let clock = TestClock()
        self.clock = clock
        settings = .test
        presets = [service.defaultPreset, service.rulePreset]
        currentID = service.defaultPreset.uniqueID
        frontmost = .rule
        engine = ReferenceModeRuleEngine(
            displayPresetService: service,
            ownBundleIdentifier: "com.example.XDRSwitcher",
            switchDelayRange: 0.01...0.01,
            coldLaunchProtectionDuration: 0.05,
            uptime: { clock.uptime },
            now: { clock.date }
        )
    }

    func launch(_ application: ActiveApplicationInfo) {
        engine.recordApplicationLaunch(application)
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
            onError: { self.error = $0 },
            onApplied: {
                self.currentID = $0.activePreset?.uniqueID
                self.appliedCount += 1
            }
        )
    }

    func terminate(_ application: ActiveApplicationInfo) {
        engine.recordApplicationTermination(application)
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
            onError: { self.error = $0 },
            onApplied: {
                self.currentID = $0.activePreset?.uniqueID
                self.appliedCount += 1
            }
        )
    }
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
            ),
            AppRule(
                appDisplayName: "GeForce NOW",
                bundleIdentifier: "com.nvidia.gfnpc.mall",
                appPath: nil,
                presetUniqueID: "rule",
                presetName: "Rule"
            )
        ],
        switchDelaySeconds: 4,
        launchAtLoginEnabled: false
    )
}

private extension ActiveApplicationInfo {
    static func geforceNow(
        processIdentifier: pid_t = 404,
        launchDate: Date? = nil,
        bundleIdentifier: String? = "com.nvidia.gfnpc.mall"
    ) -> ActiveApplicationInfo {
        ActiveApplicationInfo(
            localizedName: "GeForce NOW",
            bundleIdentifier: bundleIdentifier,
            bundleURL: nil,
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
    }

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

    static let geforceNow = ActiveApplicationInfo(
        localizedName: "GeForce NOW",
        bundleIdentifier: "com.nvidia.gfnpc.mall",
        bundleURL: nil,
        processIdentifier: 404
    )
}

private func wait(_ duration: TimeInterval = 0.04) async {
    try? await Task.sleep(for: .seconds(duration))
}

@Suite("Reference Mode automatic switching")
@MainActor
struct ReferenceModeSafetyTests {
    @Test("Automatic switch delay is fixed at four seconds without overwriting saved value")
    func fourSecondDelay() {
        #expect(XDRSwitcherSettings.defaults.switchDelaySeconds == 4)
        var settings = XDRSwitcherSettings.test
        settings.switchDelaySeconds = 0.1
        #expect(settings.safeSwitchDelaySeconds == 4)
        #expect(settings.switchDelaySeconds == 0.1)
    }

    @Test("Rule app switches after the configured debounce")
    func normalDebounce() async {
        let harness = AutomationHarness()
        harness.activate(.rule)
        await wait(0.005)
        #expect(harness.service.applyCount == 0)
        await wait()
        #expect(harness.service.appliedIDs == ["rule"])
    }

    @Test("A newly launched GeForce NOW process uses cold-launch protection")
    func geforceNowColdLaunch() async {
        let harness = AutomationHarness()
        harness.launch(.geforceNow)
        harness.activate(.geforceNow)
        await wait(0.02)
        #expect(harness.service.applyCount == 0)
        await wait(0.05)
        #expect(harness.service.appliedIDs == ["rule"])

        harness.clock.advance(by: 0.06)
        harness.currentID = "default"
        harness.activate(.geforceNow)
        await wait(0.02)
        #expect(harness.service.appliedIDs == ["rule", "rule"])
    }

    @Test("Activation before launch notification keeps ten-second protection")
    func activationBeforeLaunch() {
        let harness = AutomationHarness()
        let application = ActiveApplicationInfo.geforceNow(launchDate: harness.clock.date)
        harness.activate(application)
        let activationDeadline = harness.engine.coldLaunchDeadlineForTesting(processIdentifier: 404)
        harness.clock.advance(by: 0.01)
        harness.launch(application)
        #expect(harness.engine.coldLaunchDeadlineForTesting(processIdentifier: 404) == activationDeadline)
    }

    @Test("Recent launch date protects when launch notification is missing")
    func missingLaunchNotificationUsesLaunchDate() {
        let harness = AutomationHarness()
        harness.activate(.geforceNow(launchDate: harness.clock.date.addingTimeInterval(-0.02)))
        #expect(harness.engine.coldLaunchDeadlineForTesting(processIdentifier: 404) == harness.clock.uptime + 0.03)
    }

    @Test("First GeForce NOW PID without launch date fails closed")
    func firstSeenFallback() {
        let harness = AutomationHarness()
        harness.activate(.geforceNow)
        #expect(harness.engine.coldLaunchDeadlineForTesting(processIdentifier: 404) == harness.clock.uptime + 0.05)
    }

    @Test("A launch event without bundle ID is recovered by activation")
    func nilLaunchBundleIdentifier() {
        let harness = AutomationHarness()
        harness.launch(.geforceNow(launchDate: harness.clock.date, bundleIdentifier: nil))
        harness.activate(.geforceNow(launchDate: harness.clock.date))
        #expect(harness.engine.coldLaunchProtectionCountForTesting == 1)
    }

    @Test("Cancelled request retains protection for the same PID")
    func cancellationRetainsProtection() {
        let harness = AutomationHarness()
        let application = ActiveApplicationInfo.geforceNow(launchDate: harness.clock.date)
        harness.activate(application)
        let deadline = harness.engine.coldLaunchDeadlineForTesting(processIdentifier: 404)
        harness.activate(.other)
        harness.clock.advance(by: 0.02)
        harness.activate(application)
        #expect(harness.engine.coldLaunchDeadlineForTesting(processIdentifier: 404) == deadline)
    }

    @Test("An already-active target does not consume PID protection")
    func activeTargetRetainsProtection() {
        let harness = AutomationHarness()
        harness.currentID = "rule"
        harness.activate(.geforceNow(launchDate: harness.clock.date))
        #expect(harness.engine.coldLaunchProtectionCountForTesting == 1)
    }

    @Test("Expired protection uses normal delay and is removed")
    func expiredProtectionIsRemoved() async {
        let harness = AutomationHarness()
        let application = ActiveApplicationInfo.geforceNow(launchDate: harness.clock.date)
        harness.launch(application)
        harness.clock.advance(by: 0.06)
        harness.activate(application)
        #expect(harness.engine.coldLaunchProtectionCountForTesting == 0)
        await wait()
        #expect(harness.service.appliedIDs == ["rule"])
    }

    @Test("An old process first seen uses the normal delay")
    func oldProcessFirstSeen() async {
        let harness = AutomationHarness()
        harness.activate(.geforceNow(launchDate: harness.clock.date.addingTimeInterval(-1)))
        #expect(harness.engine.coldLaunchProtectionCountForTesting == 0)
        await wait()
        #expect(harness.service.appliedIDs == ["rule"])
    }

    @Test("Termination removes PID protection")
    func terminationRemovesProtection() {
        let harness = AutomationHarness()
        let application = ActiveApplicationInfo.geforceNow(launchDate: harness.clock.date)
        harness.activate(application)
        harness.terminate(application)
        #expect(harness.engine.coldLaunchProtectionCountForTesting == 0)
    }

    @Test("Late launch cannot shorten an existing deadline")
    func lateLaunchDoesNotShortenDeadline() {
        let harness = AutomationHarness()
        harness.activate(.geforceNow)
        let fallbackDeadline = harness.engine.coldLaunchDeadlineForTesting(processIdentifier: 404)
        harness.clock.advance(by: 0.01)
        harness.launch(.geforceNow(launchDate: harness.clock.date.addingTimeInterval(-0.04)))
        #expect(harness.engine.coldLaunchDeadlineForTesting(processIdentifier: 404) == fallbackDeadline)
    }

    @Test("An already running GeForce NOW process uses the normal delay")
    func geforceNowWarmActivation() async {
        let harness = AutomationHarness()
        harness.activate(.geforceNow(launchDate: harness.clock.date.addingTimeInterval(-1)))
        await wait()
        #expect(harness.service.appliedIDs == ["rule"])
    }

    @Test("Changing apps cancels the previous request")
    func rapidSwitchCancellation() async {
        let harness = AutomationHarness()
        harness.currentID = "unrelated"
        harness.activate(.rule)
        harness.activate(.other)
        await wait()
        #expect(harness.service.appliedIDs == ["default"])
    }

    @Test("Explicit cancellation prevents a scheduled switch from running later")
    func explicitCancellation() async {
        let harness = AutomationHarness()
        harness.activate(.rule)
        harness.engine.cancelPendingSwitch(reason: "test cancellation")
        await wait()
        #expect(harness.service.applyCount == 0)
    }

    @Test("Changing PID before execution cancels the request")
    func pidChangeCancellation() async {
        let harness = AutomationHarness()
        harness.activate(.rule)
        harness.frontmost = ActiveApplicationInfo(
            localizedName: "Rule App",
            bundleIdentifier: "com.example.rule",
            bundleURL: nil,
            processIdentifier: 999
        )
        await wait()
        #expect(harness.service.applyCount == 0)
    }

    @Test("Automatic switching off prevents calls")
    func automaticOff() async {
        let harness = AutomationHarness()
        harness.settings.automaticSwitchingEnabled = false
        harness.activate(.rule)
        await wait()
        #expect(harness.service.applyCount == 0)
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

    @Test("Missing preset reports an error without applying")
    func missingPreset() async {
        let harness = AutomationHarness()
        harness.presets = [harness.service.defaultPreset]
        harness.activate(.rule)
        await wait()
        #expect(harness.service.applyCount == 0)
        #expect(harness.error != nil)
    }

    @Test("Own-app activation preserves the external target")
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
        await wait(0.1)
        #expect(harness.service.applyCount == 1)
        #expect(harness.error != nil)
    }
}
