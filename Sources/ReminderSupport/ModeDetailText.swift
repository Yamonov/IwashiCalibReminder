import EIZOHID
import Foundation

/// Formatting for saved CN values. It never queries a device or reads the database.
enum ModeDetailText {
    static func usageMinutes(hours: UInt32?, minutes: UInt8?) -> Int64? {
        guard let hours, let minutes, minutes < 60 else { return nil }
        return Int64(hours) * 60 + Int64(minutes)
    }

    static func longCNDate(_ text: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        guard text.count == 19, let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        // CN stores wall-clock text without an offset. Preserve that clock reading.
        return longDate(date, timeZone: TimeZone.gmt)
    }

    static func nextDateDescription(readAt: String, remainingMinutes: Int64?, timeZone: TimeZone) -> String {
        guard let remainingMinutes else { return "算出できません" }
        guard remainingMinutes >= 0 else { return "期限を超過しています" }
        guard let readDate = isoDate(readAt) else { return "取得日時が不明です" }
        let timestamp = readDate.timeIntervalSince1970 + Double(remainingMinutes) * 60
        guard timestamp.isFinite, timestamp >= -62_135_596_800, timestamp <= 253_402_300_799 else {
            return "表示できる日付の範囲を超えています"
        }
        return longDate(Date(timeIntervalSince1970: timestamp), timeZone: timeZone) + "（連続使用の目安）"
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    static func longDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年M月d日（EEEE）H時mm分ss秒"
        return formatter.string(from: date)
    }

    static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }
    static func onOff(_ value: Bool) -> String { value ? "オン" : "オフ" }
    static func xy(_ value: CNJSONValue?) -> String? {
        guard let x = value?["x"]?.number, let y = value?["y"]?.number else { return nil }
        return "x \(number(x, digits: 6)) / y \(number(y, digits: 6))"
    }
    static func whiteDescription(_ value: CNJSONValue?) -> String? {
        guard let y = value?["Y"]?.number else { return nil }
        return number(y, digits: 4) + " cd/m²" + (xy(value).map { " / " + $0 } ?? "")
    }
    static func targetValue(_ value: CNJSONValue?) -> String? {
        guard let value else { return nil }
        let type = value["type"]?.string
        if type == "Min" { return "最小値" }
        if let text = value["value"]?.string { return term(text) }
        if let number = value["value"]?.number {
            let suffix = type == "Candela" ? " cd/m²" : type == "Temperature" ? " K" : type == "Percentage" ? " %" : ""
            return Self.number(number, digits: type == "Gamma" ? 2 : 1) + suffix
        }
        if let coordinate = xy(value["value"] ?? value) { return coordinate }
        return type.map(term)
    }
    static func recordStatus(_ status: String) -> String {
        ["available": "取得済み", "incompleteCalibration": "一部の記録が不足", "unassigned": "目標が未設定",
         "noCalibration": "調整記録なし", "targetNotFound": "目標の記録なし", "invalidRecord": "記録を読み取れません",
         "unsupportedModeType": "未対応のモード種別"][status] ?? status
    }
    static func term(_ text: String) -> String {
        ["CN": "ColorNavigator", "Self": "SelfCalibration", "Standard": "標準", "Native": "Native（モニター固有）",
         "Everytime": "毎回", "NoCorrection": "補正なし", "Uniformity": "均一性優先", "Brightness": "輝度優先",
         "CIE1964_10Deg": "CIE 1964 / 10度視野", "CIE1931_2Deg": "CIE 1931 / 2度視野",
         "EveryUsageTime": "モニター使用時間ごと", "CNCalibration": "ColorNavigatorによる調整",
         "None": "無効", "DCI": "DCI-P3"][text] ?? text
    }

    static func scalar(_ value: CNJSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let n): return n.rounded() == n && abs(n) < 1e16 ? number(n, digits: 0) : String(n)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .object(let values): return "\(values.count)項目"
        case .array(let values): return "\(values.count)件"
        }
    }
}
