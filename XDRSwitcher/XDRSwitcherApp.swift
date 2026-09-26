import AppKit
import SwiftUI

@main
struct XDRSwitcherApp: App {
    @State private var appState = AppState()
    @State private var activeApplicationMonitor = ActiveApplicationMonitor()
    @State private var referenceModeRuleEngine = ReferenceModeRuleEngine()
    @State private var systemEventMonitor = SystemEventMonitor()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appState: $appState)
                .task { startApplicationServices() }
                .onChange(of: appState.settings) { reevaluateReferenceModeAutomation() }
        } label: {
            Label("XDRSwitcher", systemImage: "display")
                .task { startApplicationServices() }
        }

        Settings {
            SettingsView(appState: $appState)
                .task { startApplicationServices() }
                .onChange(of: appState.settings) { reevaluateReferenceModeAutomation() }
        }
    }

    @MainActor
    private func startApplicationServices() {
        activeApplicationMonitor.start { event in
            switch event {
            case let .launched(application):
                referenceModeRuleEngine.recordLaunch(application, settings: appState.settings)
            case let .activated(application):
                appState.updateActiveApplication(application)
                evaluateReferenceModeAutomation(for: application)
            case let .terminated(application):
                referenceModeRuleEngine.recordTermination(application)
            }
        }

        systemEventMonitor.start(
            onWillTerminate: {
                cancelPendingReferenceModeSwitch(reason: "application terminating")
            },
            onWillSleep: {
                cancelPendingReferenceModeSwitch(reason: "system sleeping")
            },
            onDidWake: {
                referenceModeRuleEngine.systemDidWake()
                refreshReferenceModesAndReevaluateAutomation()
            },
            onDisplayConfigurationWillChange: {
                referenceModeRuleEngine.displayReconfigurationBegan { status, remainingSeconds in
                    appState.setAutomaticSwitchingStatus(status, remainingSeconds: remainingSeconds)
                }
                appState.setAutomaticSwitchingPending(false)
            },
            onDisplayConfigurationDidChange: {
                referenceModeRuleEngine.displayReconfigurationEnded()
                refreshReferenceModesAndReevaluateAutomation()
            }
        )
    }

    @MainActor
    private func cancelPendingReferenceModeSwitch(reason: String) {
        referenceModeRuleEngine.cancelPendingSwitch(reason: reason)
        appState.setAutomaticSwitchingPending(false)
    }

    @MainActor
    private func refreshReferenceModesAndReevaluateAutomation() {
        appState.refreshReferenceModes()
        reevaluateReferenceModeAutomation()
    }

    @MainActor
    private func reevaluateReferenceModeAutomation() {
        referenceModeRuleEngine.reevaluate(
            settings: appState.settings,
            currentReferencePresetID: appState.currentReferencePresetID,
            availableReferencePresets: appState.availableReferencePresets,
            currentFrontmostApplication: { activeApplicationMonitor.currentApplicationInfo() },
            currentSettings: { appState.settings },
            currentPresets: { appState.availableReferencePresets },
            currentPresetID: { appState.currentReferencePresetID },
            onPendingChange: { appState.setAutomaticSwitchingPending($0) },
            onStatusChange: { appState.setAutomaticSwitchingStatus($0, remainingSeconds: $1) },
            onTargetChange: { appState.setTargetReferenceModeName($0) },
            onError: { appState.setAutomaticSwitchingErrorMessage($0) },
            onApplied: { appState.updateReferenceModesAfterAutomaticSwitch(with: $0) }
        )
    }

    @MainActor
    private func evaluateReferenceModeAutomation(for application: ActiveApplicationInfo) {
        referenceModeRuleEngine.handleActiveApplicationChange(
            application,
            settings: appState.settings,
            currentReferencePresetID: appState.currentReferencePresetID,
            availableReferencePresets: appState.availableReferencePresets,
            currentFrontmostApplication: { activeApplicationMonitor.currentApplicationInfo() },
            currentSettings: { appState.settings },
            currentPresets: { appState.availableReferencePresets },
            currentPresetID: { appState.currentReferencePresetID },
            onPendingChange: { appState.setAutomaticSwitchingPending($0) },
            onStatusChange: { appState.setAutomaticSwitchingStatus($0, remainingSeconds: $1) },
            onTargetChange: { appState.setTargetReferenceModeName($0) },
            onError: { appState.setAutomaticSwitchingErrorMessage($0) },
            onApplied: { appState.updateReferenceModesAfterAutomaticSwitch(with: $0) }
        )
    }
}
