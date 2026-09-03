import Foundation

struct ReferencePreset: Identifiable, Equatable {
    let runtimeIndex: Int
    let name: String
    let uniqueID: String
    let isValid: Bool

    init(runtimeIndex: Int, name: String, uniqueID: String, isValid: Bool) {
        self.runtimeIndex = runtimeIndex
        self.name = name
        self.uniqueID = uniqueID
        self.isValid = isValid
    }

    init(runtimeIndex: Int, dictionary: CFDictionary) {
        let dictionary = dictionary as NSDictionary
        self.init(
            runtimeIndex: runtimeIndex,
            name: Self.stringValue(in: dictionary, keys: [
                "name",
                "Name",
                "presetName",
                "PresetName",
                "PresetNameString",
                "modeName",
                "ModeName",
                "localizedName",
                "LocalizedName"
            ]),
            uniqueID: Self.stringValue(in: dictionary, keys: [
                "uuid",
                "UUID",
                "uniqueID",
                "UniqueID",
                "presetID",
                "PresetID",
                "PresetUniqueID",
                "referenceModeID",
                "ReferenceModeID"
            ]),
            isValid: Self.boolValue(in: dictionary, keys: [
                "valid",
                "Valid",
                "isValid",
                "IsValid",
                "PresetValid"
            ]) ?? true
        )
    }

    var id: String {
        if !uniqueID.isEmpty {
            return uniqueID
        }

        return "preset-\(runtimeIndex)"
    }

    var displayName: String {
        if !name.isEmpty {
            return name
        }

        if !uniqueID.isEmpty {
            return uniqueID
        }

        return "Preset \(runtimeIndex)"
    }

    private static func stringValue(in dictionary: NSDictionary, keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }

            if let value = dictionary[key] as? NSString, value.length > 0 {
                return value as String
            }

            if let value = dictionary[key] as? Data, !value.isEmpty {
                return value.map { String(format: "%02x", $0) }.joined()
            }

            if let value = dictionary[key] as? NSData, value.length > 0 {
                return (value as Data).map { String(format: "%02x", $0) }.joined()
            }
        }

        return ""
    }

    private static func boolValue(in dictionary: NSDictionary, keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool {
                return value
            }

            if let value = dictionary[key] as? NSNumber {
                return value.boolValue
            }
        }

        return nil
    }
}
