import EIZOHID
import Foundation

public struct DeadlineEntry: Sendable, Identifiable {
    public let monitorID: String
    public let monitorName: String
    public let mode: CNDeadlineMode
    public var id: String { "\(monitorID)-\(mode.modeNumber)" }
    public var name: String { mode.modeName ?? "モード \(mode.modeNumber)" }
}

public struct ReminderSummary: Sendable {
    public let remainingMinutes: Int64?
    public let modes: [DeadlineEntry]
    public let isPartial: Bool

    public init(reports: [MonitorUsageReport]) {
        let minimum = reports.compactMap { $0.calibrationCountdown.earliest?.remainingMinutes }.min()
        remainingMinutes = minimum
        isPartial = reports.contains { $0.calibrationCountdown.status != "available" }
        modes = reports.flatMap { report -> [DeadlineEntry] in
            guard let earliest = report.calibrationCountdown.earliest,
                  earliest.remainingMinutes == minimum else { return [] }
            return earliest.modes.map {
                DeadlineEntry(monitorID: report.monitor.serialNumber + ":" + report.monitor.locationID,
                              monitorName: report.monitor.model, mode: $0)
            }
        }
    }
}

public enum ReminderText {
    public static func duration(_ minutes: Int64) -> String {
        let magnitude = minutes.magnitude
        return "\(magnitude / 60)時間\(magnitude % 60)分"
    }

    public static func remaining(_ minutes: Int64) -> String {
        if minutes < 0 { return "\(duration(minutes))超過" }
        if minutes == 0 { return "調整時期です" }
        return "残り\(duration(minutes))"
    }

    public static func menuTitle(_ minutes: Int64) -> String {
        if minutes == 0 { return "要調整" }
        let magnitude = minutes.magnitude
        let hours = magnitude / 60
        let remainder = magnitude % 60
        let compact = remainder == 0 ? "\(hours)h" : "\(hours)h\(remainder)m"
        return minutes < 0 ? "\(compact)超過" : "残り \(compact)"
    }

    public static func unavailable(_ report: MonitorUsageReport) -> String? {
        let history = report.calibrationHistory
        guard history.status == "available" else {
            switch history.status {
            case "databaseNotFound": return "ColorNavigatorのDBがありません。累積使用時間のみ表示します。"
            case "monitorNotFound": return "このモニターの調整記録がありません。"
            case "modeSelectionUnavailable": return "有効なモードを取得できませんでした。残り時間は不明です。"
            default: return "ColorNavigatorの調整記録を読み取れませんでした。"
            }
        }
        switch report.calibrationCountdown.status {
        case "available": return nil
        case "partiallyAvailable": return "一部のモードは残り時間を計算できません。最短時間は計算できたモードの中での値です。"
        case "disabled": return "ColorNavigatorの調整スケジュールが無効です。"
        case "unsupportedSchedule": return "モニター使用時間によるキャリブレーション間隔に対応しています。現在のスケジュールでは計算できません。"
        case "noCalculableModes": return "計算できる調整記録がありません。"
        default: return "調整間隔または使用時間の情報が不足しています。"
        }
    }

    public static func modeUnavailable(_ status: String?) -> String {
        switch status {
        case "unassigned": "調整目標が未設定"
        case "usageCounterBeforeCalibration": "累積使用時間が調整時より少ないため計算できません"
        case "usageAtCalibrationUnavailable": "調整時の累積使用時間が不明"
        default: "残り時間は不明"
        }
    }
}
