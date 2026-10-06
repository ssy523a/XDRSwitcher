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
    var settings: XDRSwitcherSettings
    var presets: [ReferencePreset]
    var currentID: String?
    var frontmost: ActiveApplicationInfo?
    var error: String?
    var appliedCount = 0
    let engine: ReferenceModeRuleEngine

    init() {
        settings = .test
        presets = [service.defaultPreset, service.rulePreset]
        currentID = service.defaultPreset.uniqueID
        frontmost = .rule
        engine = ReferenceModeRuleEngine(
            displayPresetService: service,
            ownBundleIdentifier: "com.example.XDRSwitcher",
            switchDelayRange: 0.01...0.01
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
            )
        ],
        switchDelaySeconds: 4,
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

    @Test("Changing apps cancels the previous request")
    func rapidSwitchCancellation() async {
        let harness = AutomationHarness()
        harness.activate(.rule)
        harness.activate(.other)
        await wait()
        #expect(!harness.service.appliedIDs.contains("rule"))
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
