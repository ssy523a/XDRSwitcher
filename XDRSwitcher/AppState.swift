import Foundation

struct AppState {
    var settings: XDRSwitcherSettings
    var currentApplicationName = "Not Available"
    var currentReferenceModeName = "Not Available"
    var currentReferencePresetID: String?
    var availableReferencePresets: [ReferencePreset] = []
    var selectedReferencePresetID: String?
    var referenceModeErrorMessage: String?
    var settingsErrorMessage: String?
    var isRefreshingReferenceModes = false
    var isApplyingReferenceMode = false

    private var settingsStore: SettingsStore

    init(
        settingsStore: SettingsStore = SettingsStore(),
        displayPresetService: any DisplayPresetServicing = DisplayPresetService()
    ) {
        self.settingsStore = settingsStore

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
    }

    var isAutomaticSwitchingEnabled: Bool {
        settings.automaticSwitchingEnabled
    }

    var defaultReferenceModeName: String {
        settings.defaultPresetName ?? "Not Available"
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
