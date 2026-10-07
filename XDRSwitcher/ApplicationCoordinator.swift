import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class ApplicationCoordinator {
    var appState: AppState {
        didSet {
            menuBarController?.update(with: appState)
        }
    }

    private let activeApplicationMonitor: ActiveApplicationMonitor
    private let referenceModeRuleEngine: ReferenceModeRuleEngine
    private let systemEventMonitor: SystemEventMonitor
    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?

    init() {
        let appState = AppState()
        self.appState = appState
        activeApplicationMonitor = ActiveApplicationMonitor()
        referenceModeRuleEngine = ReferenceModeRuleEngine()
        systemEventMonitor = SystemEventMonitor()

        settingsWindowController = SettingsWindowController(
            appState: Binding(
                get: { [weak self] in self?.appState ?? appState },
                set: { [weak self] value in
                    self?.appState = value
                    self?.settingsDidChange()
                }
            )
        )

        menuBarController = MenuBarController(
            appState: appState,
            onAutomaticSwitchingToggle: { [weak self] in
                self?.toggleAutomaticSwitching()
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            }
        )
        startApplicationServices()
    }

    func settingsDidChange() {
        reevaluateReferenceModeAutomation()
    }

    private func toggleAutomaticSwitching() {
        appState.setAutomaticSwitchingEnabled(!appState.isAutomaticSwitchingEnabled)
        reevaluateReferenceModeAutomation()
    }

    private func openSettings() {
        settingsWindowController?.show()
    }

    private func startApplicationServices() {
        activeApplicationMonitor.start { [weak self] event in
            guard let self else { return }
            switch event {
            case let .launched(application):
                referenceModeRuleEngine.recordApplicationLaunch(application)
            case let .terminated(application):
                referenceModeRuleEngine.recordApplicationTermination(application)
            case let .activated(application):
                appState.updateActiveApplication(application)
                evaluateReferenceModeAutomation(for: application)
            }
        }

        systemEventMonitor.start(
            onWillTerminate: { [weak self] in
                self?.referenceModeRuleEngine.cancelPendingSwitch(reason: "application terminating")
            },
            onWillSleep: { [weak self] in
                self?.referenceModeRuleEngine.cancelPendingSwitch(reason: "system will sleep")
            },
            onDidWake: { [weak self] in
                self?.refreshReferenceModesAndReevaluateAutomation()
            },
            onDisplayConfigurationWillChange: { [weak self] in
                self?.referenceModeRuleEngine.cancelPendingSwitch(reason: "display configuration changing")
            },
            onDisplayConfigurationDidChange: { [weak self] in
                self?.refreshReferenceModesAndReevaluateAutomation()
            }
        )
    }

    private func refreshReferenceModesAndReevaluateAutomation() {
        appState.refreshReferenceModes()
        reevaluateReferenceModeAutomation()
    }

    private func reevaluateReferenceModeAutomation() {
        referenceModeRuleEngine.reevaluate(
            settings: appState.settings,
            currentReferencePresetID: appState.currentReferencePresetID,
            availableReferencePresets: appState.availableReferencePresets,
            currentFrontmostApplication: { [weak self] in
                self?.activeApplicationMonitor.currentApplicationInfo()
            },
            currentSettings: { [weak self] in
                self?.appState.settings ?? .defaults
            },
            currentPresets: { [weak self] in
                self?.appState.availableReferencePresets ?? []
            },
            currentPresetID: { [weak self] in
                self?.appState.currentReferencePresetID
            },
            onError: { [weak self] in
                self?.appState.setAutomaticSwitchingErrorMessage($0)
            },
            onApplied: { [weak self] in
                self?.appState.updateReferenceModesAfterAutomaticSwitch(with: $0)
            }
        )
    }

    private func evaluateReferenceModeAutomation(for application: ActiveApplicationInfo) {
        referenceModeRuleEngine.handleActiveApplicationChange(
            application,
            settings: appState.settings,
            currentReferencePresetID: appState.currentReferencePresetID,
            availableReferencePresets: appState.availableReferencePresets,
            currentFrontmostApplication: { [weak self] in
                self?.activeApplicationMonitor.currentApplicationInfo()
            },
            currentSettings: { [weak self] in
                self?.appState.settings ?? .defaults
            },
            currentPresets: { [weak self] in
                self?.appState.availableReferencePresets ?? []
            },
            currentPresetID: { [weak self] in
                self?.appState.currentReferencePresetID
            },
            onError: { [weak self] in
                self?.appState.setAutomaticSwitchingErrorMessage($0)
            },
            onApplied: { [weak self] in
                self?.appState.updateReferenceModesAfterAutomaticSwitch(with: $0)
            }
        )
    }
}
