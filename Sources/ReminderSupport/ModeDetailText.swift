import EIZOHID
import Foundation

/// Formatting for saved CN values. It never queries a device or reads the database.
enum ModeDetailText {
    static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }
    static func onOff(_ value: Bool) -> String { value ? L10n.text("On") : L10n.text("Off") }
    static func xy(_ value: CNJSONValue?) -> String? {
        guard let x = value?["x"]?.number, let y = value?["y"]?.number else { return nil }
        return "x \(number(x, digits: 6)) / y \(number(y, digits: 6))"
    }
    static func targetValue(_ value: CNJSONValue?) -> String? {
        guard let value else { return nil }
        let type = value["type"]?.string
        if type == "Min" { return L10n.text("Minimum") }
        if let text = value["value"]?.string { return term(text) }
        if let number = value["value"]?.number {
            let suffix = type == "Candela" ? " cd/m²" : type == "Temperature" ? " K" : type == "Percentage" ? " %" : ""
            return Self.number(number, digits: type == "Gamma" ? 2 : 1) + suffix
        }
        if let coordinate = xy(value["value"] ?? value) { return coordinate }
        return type.map(term)
    }
    static func term(_ text: String) -> String {
        ["CN": "ColorNavigator", "Self": "SelfCalibration", "Standard": L10n.text("Standard"), "Native": L10n.text("Native (monitor gamut)"),
         "Everytime": L10n.text("Every time"), "NoCorrection": L10n.text("No correction"), "Uniformity": L10n.text("Uniformity priority"), "Brightness": L10n.text("Brightness priority"),
         "CIE1964_10Deg": L10n.text("CIE 1964 / 10° observer"), "CIE1931_2Deg": L10n.text("CIE 1931 / 2° observer"),
         "EveryUsageTime": L10n.text("By monitor usage"), "CNCalibration": L10n.text("Calibration with ColorNavigator"),
         "None": L10n.text("None"), "DCI": "DCI-P3"][text] ?? text
    }

}
