import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Binding var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Automatic Switching", isOn: automaticSwitchingBinding)

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Current Application", value: appState.currentApplicationName)
                    LabeledContent("Bundle Identifier", value: appState.currentApplicationBundleIdentifier)
                }

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

                    HStack {
                        Button("Make Current Mode Default") {
                            appState.useCurrentReferenceModeAsDefault()
                        }
                        .disabled(appState.currentReferencePresetID == nil)

                        Button("Apply Default Mode") {
                            appState.applyDefaultReferenceMode()
                        }
                        .disabled(
                            appState.settings.defaultPresetUniqueID == nil ||
                            appState.missingDefaultPresetID != nil ||
                            appState.isApplyingReferenceMode ||
                            appState.isRefreshingReferenceModes
                        )
                    }
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

            if let automaticSwitchingErrorMessage = appState.automaticSwitchingErrorMessage {
                Section("Automatic Switching") {
                    Text(automaticSwitchingErrorMessage)
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
                if appState.settings.appRules.isEmpty {
                    Text("No application rules have been added.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.settings.appRules) { rule in
                        AppRuleRow(
                            rule: rule,
                            presets: appState.availableReferencePresets,
                            isPresetMissing: appState.isApplicationRulePresetMissing(rule),
                            presetSelection: applicationRulePresetBinding(for: rule.id),
                            isEnabled: applicationRuleEnabledBinding(for: rule.id),
                            deleteAction: {
                                appState.deleteApplicationRule(ruleID: rule.id)
                            }
                        )
                    }
                }

                Button("Add Application") {
                    appState.addApplicationRuleFromPanel()
                }
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

    private func applicationRulePresetBinding(for ruleID: UUID) -> Binding<String> {
        Binding(
            get: {
                appState.settings.appRules.first(where: { $0.id == ruleID })?.presetUniqueID ?? ""
            },
            set: { newValue in
                appState.setApplicationRulePreset(ruleID: ruleID, presetUniqueID: newValue)
            }
        )
    }

    private func applicationRuleEnabledBinding(for ruleID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                appState.settings.appRules.first(where: { $0.id == ruleID })?.enabled ?? false
            },
            set: { newValue in
                appState.setApplicationRuleEnabled(ruleID: ruleID, isEnabled: newValue)
            }
        )
    }
}

private struct AppRuleRow: View {
    let rule: AppRule
    let presets: [ReferencePreset]
    let isPresetMissing: Bool
    let presetSelection: Binding<String>
    let isEnabled: Binding<Bool>
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                appIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.appDisplayName)
                        .font(.headline)
                    Text(rule.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Toggle("Enabled", isOn: isEnabled)
                    .labelsHidden()

                Button(role: .destructive, action: deleteAction) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete Rule")
            }

            Picker("Reference Mode", selection: presetSelection) {
                if isPresetMissing {
                    Text("\(rule.presetName) (Missing)")
                        .tag(rule.presetUniqueID)
                }

                ForEach(presets) { preset in
                    Text(preset.displayName)
                        .tag(preset.uniqueID)
                }
            }
            .disabled(presets.isEmpty)

            if isPresetMissing {
                Text("The saved Reference Mode is not available on the current display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var appIcon: some View {
        Image(nsImage: resolvedIcon)
            .resizable()
            .frame(width: 32, height: 32)
    }

    private var resolvedIcon: NSImage {
        if let appPath = rule.appPath, FileManager.default.fileExists(atPath: appPath) {
            return NSWorkspace.shared.icon(forFile: appPath)
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return NSWorkspace.shared.icon(for: .application)
    }
}
