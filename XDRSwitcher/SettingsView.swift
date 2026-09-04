import SwiftUI

struct SettingsView: View {
    @Binding var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Automatic Switching", isOn: automaticSwitchingBinding)
                LabeledContent("Current Reference Mode", value: appState.currentReferenceModeName)

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Default Reference Mode", selection: defaultReferenceModeBinding) {
                        if appState.settings.defaultPresetUniqueID == nil {
                            Text("Not Available")
                                .tag(Optional<String>.none)
                        }

                        if let missingDefaultPresetID = appState.missingDefaultPresetID {
                            Text("\(appState.defaultReferenceModeName) (Unavailable)")
                                .tag(Optional(missingDefaultPresetID))
                        }

                        ForEach(appState.availableReferencePresets) { preset in
                            Text(preset.displayName)
                                .tag(Optional(preset.uniqueID))
                        }
                    }
                    .disabled(appState.availableReferencePresets.isEmpty)

                    Button("Make Current Mode Default") {
                        appState.useCurrentReferenceModeAsDefault()
                    }
                    .disabled(appState.currentReferencePresetID == nil)
                }

                Button("Refresh") {
                    appState.refreshReferenceModes()
                }
                .disabled(appState.isRefreshingReferenceModes || appState.isApplyingReferenceMode)
            }

            if let defaultPresetAvailabilityMessage = appState.defaultPresetAvailabilityMessage {
                Section("Default Reference Mode") {
                    Text(defaultPresetAvailabilityMessage)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let errorMessage = appState.referenceModeErrorMessage {
                Section("CoreDisplay") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if let settingsErrorMessage = appState.settingsErrorMessage {
                Section("Settings") {
                    Text(settingsErrorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Reference Modes") {
                if appState.availableReferencePresets.isEmpty {
                    Text("Not Available")
                        .foregroundStyle(.secondary)
                } else {
                    List(selection: $appState.selectedReferencePresetID) {
                        ForEach(appState.availableReferencePresets) { preset in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(preset.displayName)
                                    Spacer()
                                    Text("Index \(preset.runtimeIndex)")
                                        .foregroundStyle(.secondary)
                                }

                                if !preset.uniqueID.isEmpty {
                                    Text(preset.uniqueID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }

                                if !preset.isValid {
                                    Text("Invalid")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            .tag(preset.uniqueID)
                        }
                    }
                    .frame(minHeight: 140)

                    HStack {
                        Button("Apply") {
                            appState.applySelectedReferenceMode()
                        }
                        .disabled(
                            appState.selectedReferencePresetID == nil ||
                            appState.isApplyingReferenceMode ||
                            appState.isRefreshingReferenceModes
                        )

                        if appState.isApplyingReferenceMode {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section("Application Rules") {
                Button("Add Application") {}
                    .disabled(true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 690)
    }

    private var automaticSwitchingBinding: Binding<Bool> {
        Binding(
            get: { appState.isAutomaticSwitchingEnabled },
            set: { appState.setAutomaticSwitchingEnabled($0) }
        )
    }

    private var defaultReferenceModeBinding: Binding<String?> {
        Binding(
            get: { appState.settings.defaultPresetUniqueID },
            set: { newValue in
                guard let newValue else {
                    return
                }

                appState.setDefaultReferencePreset(uniqueID: newValue)
            }
        )
    }
}
