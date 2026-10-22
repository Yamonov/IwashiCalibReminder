import EIZOHID
import Foundation

public struct DeadlineEntry: Sendable, Identifiable {
    public let monitorID: String
    public let monitorName: String
    public let mode: CNDeadlineMode
    public var id: String { "\(monitorID)-\(mode.modeNumber)" }
    public var name: String { mode.modeName ?? L10n.text("Mode %ld", mode.modeNumber) }
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
        return L10n.text("%llu h %llu min", magnitude / 60, magnitude % 60)
    }

    public static func remaining(_ minutes: Int64) -> String {
        if minutes < 0 { return L10n.text("%@ overdue", duration(minutes)) }
        if minutes == 0 { return L10n.text("Calibration is due") }
        return L10n.text("%@ remaining", duration(minutes))
    }

    public static func menuTitle(_ minutes: Int64) -> String {
        if minutes == 0 { return L10n.text("Calibration due") }
        let magnitude = minutes.magnitude
        let hours = magnitude / 60
        let remainder = magnitude % 60
        let compact = remainder == 0 ? "\(hours)h" : "\(hours)h\(remainder)m"
        return minutes < 0 ? L10n.text("%@ overdue", compact) : L10n.text("Remaining: %@", compact)
    }

    public static func unavailable(_ report: MonitorUsageReport) -> String? {
        let history = report.calibrationHistory
        guard history.status == "available" else {
            switch history.status {
            case "databaseNotFound": return L10n.text("The ColorNavigator database is missing. Only total usage is shown.")
            case "monitorNotFound": return L10n.text("No calibration history is available for this monitor.")
            case "modeSelectionUnavailable": return L10n.text("Unable to read monitor information")
            default: return L10n.text("Unable to read the ColorNavigator calibration history.")
            }
        }
        switch report.calibrationCountdown.status {
        case "available": return nil
        case "partiallyAvailable": return L10n.text("Remaining time is unavailable for some modes. The earliest deadline includes only modes with sufficient data.")
        case "disabled": return nil
        case "unsupportedSchedule": return L10n.text("Remaining time cannot be calculated for this calibration schedule")
        case "noCalculableModes": return L10n.text("No calibration records have enough information to calculate remaining time.")
        default: return L10n.text("Calibration interval or usage information is incomplete.")
        }
    }

    public static func modeUnavailable(_ status: String?) -> String {
        switch status {
        case "unassigned": L10n.text("No calibration target assigned")
        case "usageCounterBeforeCalibration": L10n.text("Current usage is below the calibration baseline")
        case "usageAtCalibrationUnavailable": L10n.text("Usage at calibration is unknown")
        default: L10n.text("Remaining time is unknown")
        }
    }
}
