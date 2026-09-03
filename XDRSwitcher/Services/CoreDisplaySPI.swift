import CoreGraphics
import Darwin
import Foundation

enum CoreDisplayError: LocalizedError, Equatable {
    case frameworkLoadFailed(path: String, detail: String)
    case missingSymbol(String)
    case displayListUnavailable(CGError)
    case builtInDisplayUnavailable
    case invalidPresetCount(Int32)
    case invalidActivePresetIndex(Int32)
    case presetDictionaryUnavailable(index: Int)
    case presetNotFound(uniqueID: String)
    case presetSwitchFailed(index: Int, status: Int32)
    case presetSwitchVerificationFailed(expectedUniqueID: String, actualUniqueID: String?, status: Int32)

    var errorDescription: String? {
        switch self {
        case let .frameworkLoadFailed(path, detail):
            return "Unable to load CoreDisplay at \(path): \(detail)"
        case let .missingSymbol(symbol):
            return "CoreDisplay does not provide the required symbol: \(symbol)"
        case let .displayListUnavailable(error):
            return "Unable to read the display list: \(error)"
        case .builtInDisplayUnavailable:
            return "No built-in display was found."
        case let .invalidPresetCount(count):
            return "CoreDisplay returned an invalid preset count: \(count)"
        case let .invalidActivePresetIndex(index):
            return "CoreDisplay returned an invalid active preset index: \(index)"
        case let .presetDictionaryUnavailable(index):
            return "CoreDisplay did not return a preset dictionary for index \(index)."
        case let .presetNotFound(uniqueID):
            return "The selected Reference Mode is no longer available: \(uniqueID)"
        case let .presetSwitchFailed(index, status):
            return "CoreDisplay failed to apply Reference Mode index \(index). Status: \(status)"
        case let .presetSwitchVerificationFailed(expectedUniqueID, actualUniqueID, status):
            return "Reference Mode change could not be verified. Expected \(expectedUniqueID), actual \(actualUniqueID ?? "Not Available"). CoreDisplay status: \(status)"
        }
    }
}

protocol CoreDisplayPresetControlling {
    func presetCount(for displayID: CGDirectDisplayID) throws -> Int
    func activePresetIndex(for displayID: CGDirectDisplayID) throws -> Int
    func presetDictionary(for displayID: CGDirectDisplayID, index: Int) throws -> CFDictionary
    func setActivePresetIndex(_ index: Int, for displayID: CGDirectDisplayID) throws -> Int32
}

final class CoreDisplaySPI: CoreDisplayPresetControlling {
    private static let frameworkPath = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"

    private typealias GetPresetCountFunction = @convention(c) (CGDirectDisplayID) -> Int32
    private typealias GetActivePresetFunction = @convention(c) (CGDirectDisplayID) -> Int32
    private typealias CopyPresetFunction = @convention(c) (CGDirectDisplayID, Int32) -> Unmanaged<CFDictionary>?
    private typealias SetActivePresetFunction = @convention(c) (CGDirectDisplayID, Int32) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let getPresetCount: GetPresetCountFunction
    private let getActivePreset: GetActivePresetFunction
    private let copyPreset: CopyPresetFunction
    private let setActivePreset: SetActivePresetFunction?

    init() throws {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            throw CoreDisplayError.frameworkLoadFailed(
                path: Self.frameworkPath,
                detail: Self.lastDynamicLoaderError()
            )
        }

        do {
            self.handle = handle
            self.getPresetCount = try Self.resolve("CoreDisplay_Display_GetPresetCount", in: handle)
            self.getActivePreset = try Self.resolve(
                ["CoreDisplay_Display_GetActivePresetIndex", "CoreDisplay_Display_GetActivePreset"],
                in: handle
            )
            self.copyPreset = try Self.resolve("CoreDisplay_Display_CopyPreset", in: handle)
            self.setActivePreset = Self.resolveOptional("CoreDisplay_Display_SetActivePresetIndex", in: handle)
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        dlclose(handle)
    }

    func presetCount(for displayID: CGDirectDisplayID) throws -> Int {
        let count = getPresetCount(displayID)
        guard count >= 0 else {
            throw CoreDisplayError.invalidPresetCount(count)
        }

        return Int(count)
    }

    func activePresetIndex(for displayID: CGDirectDisplayID) throws -> Int {
        let index = getActivePreset(displayID)
        guard index >= 0 else {
            throw CoreDisplayError.invalidActivePresetIndex(index)
        }

        return Int(index)
    }

    func presetDictionary(for displayID: CGDirectDisplayID, index: Int) throws -> CFDictionary {
        guard let unmanagedDictionary = copyPreset(displayID, Int32(index)) else {
            throw CoreDisplayError.presetDictionaryUnavailable(index: index)
        }

        return unmanagedDictionary.takeRetainedValue()
    }

    func setActivePresetIndex(_ index: Int, for displayID: CGDirectDisplayID) throws -> Int32 {
        guard let setActivePreset else {
            throw CoreDisplayError.missingSymbol("CoreDisplay_Display_SetActivePresetIndex")
        }

        return setActivePreset(displayID, Int32(index))
    }

    private static func resolve<Function>(_ symbol: String, in handle: UnsafeMutableRawPointer) throws -> Function {
        try resolve([symbol], in: handle)
    }

    private static func resolve<Function>(_ symbols: [String], in handle: UnsafeMutableRawPointer) throws -> Function {
        for symbol in symbols {
            if let rawSymbol = dlsym(handle, symbol) {
                return cast(rawSymbol, to: Function.self)
            }
        }

        throw CoreDisplayError.missingSymbol(symbols.joined(separator: ", "))
    }

    private static func resolveOptional<Function>(_ symbol: String, in handle: UnsafeMutableRawPointer) -> Function? {
        guard let rawSymbol = dlsym(handle, symbol) else {
            return nil
        }

        return cast(rawSymbol, to: Function.self)
    }

    private static func cast<Function>(_ rawSymbol: UnsafeMutableRawPointer, to type: Function.Type) -> Function {
        // CoreDisplay is a private C SPI loaded dynamically. The symbol name is checked with dlsym,
        // and the unsafe cast is intentionally isolated here so the rest of the app uses typed closures.
        return unsafeBitCast(rawSymbol, to: Function.self)
    }

    private static func lastDynamicLoaderError() -> String {
        guard let error = dlerror() else {
            return "Unknown dynamic loader error"
        }

        return String(cString: error)
    }
}
