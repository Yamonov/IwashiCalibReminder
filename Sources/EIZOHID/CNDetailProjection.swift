import Foundation

/// Full records remain available for diagnostics; routine reads retain only what they display.
public enum CNHistoryDetail: Equatable, Sendable {
    case summary, menu, full
}

private struct CNField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private typealias CNFields = KeyedDecodingContainer<CNField>

private func selected(_ fields: CNFields, _ names: [String]) -> [String: CNJSONValue] {
    var values: [String: CNJSONValue] = [:]
    for name in names {
        if let value = try? fields.decode(CNJSONValue.self, forKey: CNField(name)) { values[name] = value }
    }
    return values
}

private func nested(_ fields: CNFields, _ name: String) -> CNFields? {
    try? fields.nestedContainer(keyedBy: CNField.self, forKey: CNField(name))
}

struct CNMenuTargetDetails: Decodable {
    let value: CNJSONValue

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CNField.self)
        var result = selected(fields, ["profileUpdateRule"])
        if let setting = nested(fields, "targetSetting") {
            result["targetSetting"] = .object(selected(setting,
                ["modeType", "brightness", "whitePoint", "gamma", "gamut", "calibrationPolicy"]))
        }
        if let policy = nested(fields, "profilePolicy") {
            result["profilePolicy"] = .object(selected(policy, ["toneCurve", "profileVersion", "reflectBlackLevels"]))
        }
        if let profile = nested(fields, "profileData") {
            var values: [String: CNJSONValue] = [:]
            if let stored = nested(profile, "storedData") {
                values["storedData"] = .object(selected(stored, ["path", "toneCurve", "profileVersion", "reflectBlackLevels"]))
            }
            // Presence is sufficient for the menu. Never retain imported ICC bytes.
            if nested(profile, "concreteBinary") != nil { values["concreteBinary"] = .object([:]) }
            result["profileData"] = .object(values)
        }
        value = .object(result)
    }
}

struct CNMenuResultDetails: Decodable {
    let value: CNJSONValue

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CNField.self)
        var result: [String: CNJSONValue] = [:]
        if let basic = nested(fields, "basicData") {
            var values: [String: CNJSONValue] = [:]
            if let executor = nested(basic, "executor") { values["executor"] = .object(selected(executor, ["type"])) }
            if let sensor = nested(basic, "sensorInformation") {
                values["sensorInformation"] = .object(selected(sensor, ["name", "colorSensorID", "colorMatchingFunction"]))
            }
            result["basicData"] = .object(values)
        }
        if let justCalibrated = nested(fields, "justCalibratedWhite"), let xyz = nested(justCalibrated, "XYZ") {
            result["justCalibratedWhite"] = .object(["XYZ": .object(selected(xyz, ["X", "Y", "Z", "x", "y", "z"]))])
        }
        for name in ["measurementDataCMF", "measurementData"] {
            guard var patches = try? fields.nestedUnkeyedContainer(forKey: CNField(name)) else { continue }
            while !patches.isAtEnd {
                // superDecoder advances even when a patch has an unsupported value type.
                let decoder = try patches.superDecoder()
                guard let patch = try? WhitePatch(from: decoder), let white = patch.value else { continue }
                result[name] = .array([white])
                break
            }
        }
        value = .object(result)
    }

    private struct WhitePatch: Decodable {
        let value: CNJSONValue?
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CNField.self)
            guard let rgb = nested(fields, "RGB"),
                  (try? rgb.decode(Double.self, forKey: CNField("R"))) == 1,
                  (try? rgb.decode(Double.self, forKey: CNField("G"))) == 1,
                  (try? rgb.decode(Double.self, forKey: CNField("B"))) == 1,
                  let xyz = nested(fields, "XYZ") else { value = nil; return }
            value = .object(["RGB": .object(["R": .number(1), "G": .number(1), "B": .number(1)]),
                             "XYZ": .object(selected(xyz, ["X", "Y", "Z", "x", "y", "z"]))])
        }
    }
}
