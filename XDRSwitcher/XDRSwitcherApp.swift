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
                .task {
                    startApplicationServices()
                }
                .onChange(of: appState.settings) {
                    reevaluateReferenceModeAutomation()
                }
        } label: {
            Label("XDRSwitcher", systemImage: "display")
                .task {
                    startApplicationServices()
                }
        }

        Settings {
            SettingsView(appState: $appState)
                .task {
                    startApplicationServices()
                }
                .onChange(of: appState.settings) {
                    reevaluateReferenceModeAutomation()
                }
        }
    }

    @MainActor
    private func startApplicationServices() {
        startActiveApplicationMonitoring()
        startSystemEventMonitoring()
    }

    @MainActor
    private func startActiveApplicationMonitoring() {
        activeApplicationMonitor.start { activeApplication in
            appState.updateActiveApplication(activeApplication)
            evaluateReferenceModeAutomation(for: activeApplication)
        }
    }

    @MainActor
    private func startSystemEventMonitoring() {
        systemEventMonitor.start(
            onWillTerminate: {
                cancelPendingReferenceModeSwitch()
            },
            onWillSleep: {
                cancelPendingReferenceModeSwitch()
            },
            onDidWake: {
                refreshReferenceModesAndReevaluateAutomation()
            },
            onDisplayConfigurationWillChange: {
                cancelPendingReferenceModeSwitch()
            },
            onDisplayConfigurationDidChange: {
                refreshReferenceModesAndReevaluateAutomation()
            }
        )
    }

    @MainActor
    private func cancelPendingReferenceModeSwitch() {
        referenceModeRuleEngine.cancelPendingSwitch()
        appState.setAutomaticSwitchingPending(false)
    }

    @MainActor
    private func refreshReferenceModesAndReevaluateAutomation() {
        cancelPendingReferenceModeSwitch()
        appState.refreshReferenceModes()
        reevaluateReferenceModeAutomation()
    }

    @MainActor
    private func reevaluateReferenceModeAutomation() {
        referenceModeRuleEngine.reevaluate(
            settings: appState.settings,
            currentReferencePresetID: appState.currentReferencePresetID,
            availableReferencePresets: appState.availableReferencePresets,
            currentFrontmostApplication: {
                activeApplicationMonitor.currentApplicationInfo()
            },
            onPendingChange: { isPending in
                appState.setAutomaticSwitchingPending(isPending)
            },
            onTargetChange: { targetName in
                appState.setTargetReferenceModeName(targetName)
            },
            onError: { message in
                appState.setAutomaticSwitchingErrorMessage(message)
            },
            onApplied: { snapshot in
                appState.updateReferenceModesAfterAutomaticSwitch(with: snapshot)
            }
        )
    }

    @MainActor
    private func evaluateReferenceModeAutomation(for activeApplication: ActiveApplicationInfo) {
        referenceModeRuleEngine.handleActiveApplicationChange(
            activeApplication,
            settings: appState.settings,
            currentReferencePresetID: appState.currentReferencePresetID,
            availableReferencePresets: appState.availableReferencePresets,
            currentFrontmostApplication: {
                activeApplicationMonitor.currentApplicationInfo()
            },
            onPendingChange: { isPending in
                appState.setAutomaticSwitchingPending(isPending)
            },
            onTargetChange: { targetName in
                appState.setTargetReferenceModeName(targetName)
            },
            onError: { message in
                appState.setAutomaticSwitchingErrorMessage(message)
            },
            onApplied: { snapshot in
                appState.updateReferenceModesAfterAutomaticSwitch(with: snapshot)
            }
        )
    }
}
