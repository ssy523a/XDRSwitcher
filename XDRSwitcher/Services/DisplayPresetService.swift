import CoreGraphics
import Foundation

struct DisplayPresetSnapshot: Equatable {
    let displayID: CGDirectDisplayID
    let presets: [ReferencePreset]
    let activePreset: ReferencePreset?
}

protocol DisplayPresetServicing {
    func loadBuiltInDisplayPresets() throws -> DisplayPresetSnapshot
    func applyPreset(uniqueID: String) throws -> DisplayPresetSnapshot
}

struct DisplayPresetService: DisplayPresetServicing {
    private let coreDisplayFactory: () throws -> any CoreDisplayPresetControlling
    private let displayIDProvider: () throws -> CGDirectDisplayID

    init(
        coreDisplayFactory: @escaping () throws -> any CoreDisplayPresetControlling = { try CoreDisplaySPI() },
        displayIDProvider: @escaping () throws -> CGDirectDisplayID = { try Self.builtInDisplayID() }
    ) {
        self.coreDisplayFactory = coreDisplayFactory
        self.displayIDProvider = displayIDProvider
    }

    func loadBuiltInDisplayPresets() throws -> DisplayPresetSnapshot {
        let displayID = try displayIDProvider()
        let coreDisplay = try coreDisplayFactory()
        return try loadPresets(for: displayID, using: coreDisplay)
    }

    func applyPreset(uniqueID: String) throws -> DisplayPresetSnapshot {
        let displayID = try displayIDProvider()
        let coreDisplay = try coreDisplayFactory()
        let currentSnapshot = try loadPresets(for: displayID, using: coreDisplay)

        guard let targetPreset = currentSnapshot.presets.first(where: { $0.uniqueID == uniqueID && $0.isValid }) else {
            throw CoreDisplayError.presetNotFound(uniqueID: uniqueID)
        }

        if currentSnapshot.activePreset?.uniqueID == targetPreset.uniqueID {
            return currentSnapshot
        }

        let status = try coreDisplay.setActivePresetIndex(targetPreset.runtimeIndex, for: displayID)
        print("XDRSwitcher CoreDisplay set active preset index=\(targetPreset.runtimeIndex) status=\(status)")
        guard status >= 0 else {
            throw CoreDisplayError.presetSwitchFailed(index: targetPreset.runtimeIndex, status: status)
        }

        let updatedSnapshot = try loadPresets(for: displayID, using: coreDisplay)
        guard updatedSnapshot.activePreset?.uniqueID == targetPreset.uniqueID else {
            throw CoreDisplayError.presetSwitchVerificationFailed(
                expectedUniqueID: targetPreset.uniqueID,
                actualUniqueID: updatedSnapshot.activePreset?.uniqueID,
                status: status
            )
        }

        return updatedSnapshot
    }

    private func loadPresets(
        for displayID: CGDirectDisplayID,
        using coreDisplay: any CoreDisplayPresetControlling
    ) throws -> DisplayPresetSnapshot {
        let presetCount = try coreDisplay.presetCount(for: displayID)
        let activePresetIndex = try coreDisplay.activePresetIndex(for: displayID)

        var allPresets: [ReferencePreset] = []
        allPresets.reserveCapacity(presetCount)

        for runtimeIndex in 0..<presetCount {
            let dictionary = try coreDisplay.presetDictionary(for: displayID, index: runtimeIndex)
            allPresets.append(ReferencePreset(runtimeIndex: runtimeIndex, dictionary: dictionary))
        }

        let presets = allPresets.filter(\.isValid)
        let activePreset = presets.first { $0.runtimeIndex == activePresetIndex }
        log(
            displayID: displayID,
            presetCount: presetCount,
            usablePresetCount: presets.count,
            presets: allPresets,
            activePresetIndex: activePresetIndex
        )

        return DisplayPresetSnapshot(displayID: displayID, presets: presets, activePreset: activePreset)
    }

    private static func builtInDisplayID() throws -> CGDirectDisplayID {
        var displayCount: UInt32 = 0
        let countError = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard countError == .success else {
            throw CoreDisplayError.displayListUnavailable(countError)
        }

        guard displayCount > 0 else {
            throw CoreDisplayError.builtInDisplayUnavailable
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listError = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }
        guard listError == .success else {
            throw CoreDisplayError.displayListUnavailable(listError)
        }

        guard let builtInDisplay = displays.prefix(Int(displayCount)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw CoreDisplayError.builtInDisplayUnavailable
        }

        return builtInDisplay
    }

    private func log(
        displayID: CGDirectDisplayID,
        presetCount: Int,
        usablePresetCount: Int,
        presets: [ReferencePreset],
        activePresetIndex: Int
    ) {
        print("XDRSwitcher CoreDisplay displayID: \(displayID)")
        print("XDRSwitcher CoreDisplay preset slot count: \(presetCount)")
        print("XDRSwitcher CoreDisplay usable preset count: \(usablePresetCount)")
        print("XDRSwitcher CoreDisplay active preset index: \(activePresetIndex)")

        for preset in presets {
            print(
                "XDRSwitcher CoreDisplay preset index=\(preset.runtimeIndex) " +
                "name=\(preset.displayName) uniqueID=\(preset.uniqueID) valid=\(preset.isValid)"
            )
        }
    }
}
