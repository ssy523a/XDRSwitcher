import Foundation

struct AppState {
    var settings: XDRSwitcherSettings
    var currentApplicationName = "Not Available"
    var currentApplicationBundleIdentifier = "Not Available"
    var currentApplicationPath: String?
    var currentReferenceModeName = "Not Available"
    var currentReferencePresetID: String?
    var availableReferencePresets: [ReferencePreset] = []
    var selectedReferencePresetID: String?
    var referenceModeErrorMessage: String?
    var settingsErrorMessage: String?
    var automaticSwitchingErrorMessage: String?
    var launchAtLoginStatus = LaunchAtLoginStatus.notRegistered
    var launchAtLoginErrorMessage: String?
    var targetReferenceModeName = "Not Available"
    var isPendingReferenceModeSwitch = false
    var isRefreshingReferenceModes = false
    var isApplyingReferenceMode = false

    private var settingsStore: SettingsStore
    private var launchAtLoginService: any LaunchAtLoginServicing

    init(
        settingsStore: SettingsStore = SettingsStore(),
        displayPresetService: any DisplayPresetServicing = DisplayPresetService(),
        launchAtLoginService: any LaunchAtLoginServicing = LaunchAtLoginService()
    ) {
        self.settingsStore = settingsStore
        self.launchAtLoginService = launchAtLoginService

        do {
            if let savedSettings = try settingsStore.loadSettings() {
                settings = savedSettings
                loadInitialReferenceModes(using: displayPresetService)
            } else {
                settings = XDRSwitcherSettings.defaults
                try initializeDefaultReferenceMode(using: displayPresetService)
                try persistSettings()
            }
        } catch {
            settings = XDRSwitcherSettings.defaults
            settingsErrorMessage = error.localizedDescription
            print("XDRSwitcher settings error: \(error.localizedDescription)")
        }

        refreshLaunchAtLoginStatus()
    }

    var isAutomaticSwitchingEnabled: Bool {
        settings.automaticSwitchingEnabled
    }

    var defaultReferenceModeName: String {
        settings.defaultPresetName ?? "Not Available"
    }

    var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus.isToggleOn
    }

    var defaultPresetAvailabilityMessage: String? {
        guard missingDefaultPresetID != nil else {
            return nil
        }

        return "Saved Default Reference Mode is not available on the current display."
    }

    var missingDefaultPresetID: String? {
        guard let defaultPresetUniqueID = settings.defaultPresetUniqueID else {
            return nil
        }

        if availableReferencePresets.isEmpty {
            return nil
        }

        guard availableReferencePresets.contains(where: { $0.uniqueID == defaultPresetUniqueID && $0.isValid }) else {
            return defaultPresetUniqueID
        }

        return nil
    }

    mutating func setAutomaticSwitchingEnabled(_ isEnabled: Bool) {
        settings.automaticSwitchingEnabled = isEnabled
        saveSettings()
    }

    mutating func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = launchAtLoginService.currentStatus()
    }

    mutating func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        launchAtLoginErrorMessage = nil

        do {
            launchAtLoginStatus = try launchAtLoginService.setEnabled(isEnabled)
            settings.launchAtLoginEnabled = launchAtLoginStatus.isToggleOn
            saveSettings()
        } catch {
            launchAtLoginErrorMessage = error.localizedDescription
            refreshLaunchAtLoginStatus()
            print("XDRSwitcher Launch at Login error: \(error.localizedDescription)")
        }
    }

    func openLaunchAtLoginSystemSettings() {
        launchAtLoginService.openSystemSettingsLoginItems()
    }

    mutating func updateActiveApplication(_ applicationInfo: ActiveApplicationInfo) {
        currentApplicationName = applicationInfo.displayName
        currentApplicationBundleIdentifier = applicationInfo.bundleIdentifier ?? "Not Available"
        currentApplicationPath = applicationInfo.bundleURL?.path
        print(
            "XDRSwitcher active application name=\(currentApplicationName) " +
            "bundleIdentifier=\(currentApplicationBundleIdentifier) " +
            "path=\(currentApplicationPath ?? "Not Available")"
        )
    }

    mutating func setDefaultReferencePreset(uniqueID: String) {
        guard let preset = availableReferencePresets.first(where: { $0.uniqueID == uniqueID && $0.isValid }) else {
            settingsErrorMessage = "The selected Default Reference Mode is not available."
            return
        }

        settings.defaultPresetUniqueID = preset.uniqueID
        settings.defaultPresetName = preset.displayName
        saveSettings()
    }

    mutating func useCurrentReferenceModeAsDefault() {
        guard let activePreset = activeReferencePreset() else {
            settingsErrorMessage = "Current Reference Mode is not available."
            return
        }

        settings.defaultPresetUniqueID = activePreset.uniqueID
        settings.defaultPresetName = activePreset.displayName
        saveSettings()
    }

    mutating func applyDefaultReferenceMode(using service: any DisplayPresetServicing = DisplayPresetService()) {
        guard let defaultPresetUniqueID = settings.defaultPresetUniqueID else {
            referenceModeErrorMessage = "Default Reference Mode is not set."
            return
        }

        guard missingDefaultPresetID == nil else {
            referenceModeErrorMessage = "Saved Default Reference Mode is not available on the current display."
            return
        }

        isApplyingReferenceMode = true
        referenceModeErrorMessage = nil

        defer {
            isApplyingReferenceMode = false
        }

        do {
            let snapshot = try service.applyPreset(uniqueID: defaultPresetUniqueID)
            updateReferenceModeState(with: snapshot)
        } catch {
            referenceModeErrorMessage = error.localizedDescription
            print("XDRSwitcher CoreDisplay apply default error: \(error.localizedDescription)")
        }
    }

    mutating func refreshReferenceModes(using service: any DisplayPresetServicing = DisplayPresetService()) {
        isRefreshingReferenceModes = true
        referenceModeErrorMessage = nil

        defer {
            isRefreshingReferenceModes = false
        }

        do {
            let snapshot = try service.loadBuiltInDisplayPresets()
            updateReferenceModeState(with: snapshot)
        } catch {
            availableReferencePresets = []
            selectedReferencePresetID = nil
            currentReferenceModeName = "Not Available"
            currentReferencePresetID = nil
            referenceModeErrorMessage = error.localizedDescription
            print("XDRSwitcher CoreDisplay error: \(error.localizedDescription)")
        }
    }

    mutating func applySelectedReferenceMode(using service: any DisplayPresetServicing = DisplayPresetService()) {
        guard let selectedReferencePresetID else {
            referenceModeErrorMessage = "Select a Reference Mode before applying."
            return
        }

        isApplyingReferenceMode = true
        referenceModeErrorMessage = nil

        defer {
            isApplyingReferenceMode = false
        }

        do {
            let snapshot = try service.applyPreset(uniqueID: selectedReferencePresetID)
            updateReferenceModeState(with: snapshot)
        } catch {
            referenceModeErrorMessage = error.localizedDescription
            print("XDRSwitcher CoreDisplay apply error: \(error.localizedDescription)")
        }
    }

    mutating func setAutomaticSwitchingPending(_ isPending: Bool) {
        isPendingReferenceModeSwitch = isPending
    }

    mutating func setTargetReferenceModeName(_ name: String) {
        targetReferenceModeName = name
    }

    mutating func setAutomaticSwitchingErrorMessage(_ message: String?) {
        automaticSwitchingErrorMessage = message
    }

    mutating func updateReferenceModesAfterAutomaticSwitch(with snapshot: DisplayPresetSnapshot) {
        updateReferenceModeState(with: snapshot)
    }

    @MainActor
    mutating func addApplicationRuleFromPanel() {
        addApplicationRuleFromPanel(using: ApplicationSelectionService())
    }

    @MainActor
    mutating func addApplicationRuleFromPanel(using selectionService: ApplicationSelectionService) {
        do {
            guard let selectedApplication = try selectionService.selectApplication() else {
                return
            }

            try addApplicationRule(for: selectedApplication)
        } catch {
            settingsErrorMessage = error.localizedDescription
            print("XDRSwitcher application rule error: \(error.localizedDescription)")
        }
    }

    mutating func addApplicationRule(for selectedApplication: SelectedApplication) throws {
        settingsErrorMessage = nil

        guard !settings.appRules.contains(where: { $0.bundleIdentifier == selectedApplication.bundleIdentifier }) else {
            settingsErrorMessage = "A rule for \(selectedApplication.bundleIdentifier) already exists."
            return
        }

        guard let preset = initialPresetForNewRule() else {
            settingsErrorMessage = "Refresh Reference Modes before adding an application rule."
            return
        }

        settings.appRules.append(
            AppRule(
                appDisplayName: selectedApplication.appDisplayName,
                bundleIdentifier: selectedApplication.bundleIdentifier,
                appPath: selectedApplication.appPath,
                presetUniqueID: preset.uniqueID,
                presetName: preset.displayName,
                enabled: true
            )
        )
        try persistSettings()
    }

    mutating func setApplicationRulePreset(ruleID: UUID, presetUniqueID: String) {
        guard let preset = availableReferencePresets.first(where: { $0.uniqueID == presetUniqueID && $0.isValid }) else {
            settingsErrorMessage = "The selected Reference Mode is not available."
            return
        }

        guard let ruleIndex = settings.appRules.firstIndex(where: { $0.id == ruleID }) else {
            settingsErrorMessage = "The selected application rule no longer exists."
            return
        }

        settings.appRules[ruleIndex].presetUniqueID = preset.uniqueID
        settings.appRules[ruleIndex].presetName = preset.displayName
        saveSettings()
    }

    mutating func setApplicationRuleEnabled(ruleID: UUID, isEnabled: Bool) {
        guard let ruleIndex = settings.appRules.firstIndex(where: { $0.id == ruleID }) else {
            settingsErrorMessage = "The selected application rule no longer exists."
            return
        }

        settings.appRules[ruleIndex].enabled = isEnabled
        saveSettings()
    }

    mutating func deleteApplicationRule(ruleID: UUID) {
        settings.appRules.removeAll { $0.id == ruleID }
        saveSettings()
    }

    func isApplicationRulePresetMissing(_ rule: AppRule) -> Bool {
        guard !availableReferencePresets.isEmpty else {
            return false
        }

        return !availableReferencePresets.contains { $0.uniqueID == rule.presetUniqueID && $0.isValid }
    }

    private mutating func initializeDefaultReferenceMode(using service: any DisplayPresetServicing) throws {
        let snapshot = try service.loadBuiltInDisplayPresets()
        updateReferenceModeState(with: snapshot)

        if let activePreset = snapshot.activePreset {
            settings.defaultPresetUniqueID = activePreset.uniqueID
            settings.defaultPresetName = activePreset.displayName
        }
    }

    private mutating func loadInitialReferenceModes(using service: any DisplayPresetServicing) {
        do {
            let snapshot = try service.loadBuiltInDisplayPresets()
            updateReferenceModeState(with: snapshot)
        } catch {
            referenceModeErrorMessage = error.localizedDescription
            print("XDRSwitcher CoreDisplay initial refresh error: \(error.localizedDescription)")
        }
    }

    private mutating func updateReferenceModeState(with snapshot: DisplayPresetSnapshot) {
        availableReferencePresets = snapshot.presets
        currentReferenceModeName = snapshot.activePreset?.displayName ?? "Not Available"
        currentReferencePresetID = snapshot.activePreset?.uniqueID

        if let selectedReferencePresetID,
           !snapshot.presets.contains(where: { $0.uniqueID == selectedReferencePresetID }) {
            self.selectedReferencePresetID = nil
        }
    }

    private func activeReferencePreset() -> ReferencePreset? {
        guard let currentReferencePresetID else {
            return nil
        }

        return availableReferencePresets.first { $0.uniqueID == currentReferencePresetID && $0.isValid }
    }

    private func initialPresetForNewRule() -> ReferencePreset? {
        if let defaultPresetUniqueID = settings.defaultPresetUniqueID,
           let defaultPreset = availableReferencePresets.first(where: { $0.uniqueID == defaultPresetUniqueID && $0.isValid }) {
            return defaultPreset
        }

        if let activePreset = activeReferencePreset() {
            return activePreset
        }

        return availableReferencePresets.first { $0.isValid }
    }

    private mutating func saveSettings() {
        do {
            try persistSettings()
        } catch {
            settingsErrorMessage = error.localizedDescription
            print("XDRSwitcher settings save error: \(error.localizedDescription)")
        }
    }

    private func persistSettings() throws {
        try settingsStore.save(settings)
    }
}
