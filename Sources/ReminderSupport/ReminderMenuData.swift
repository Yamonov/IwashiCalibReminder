import EIZOHID
import Foundation

public struct ReminderMenuRow: Sendable, Identifiable {
    public let monitorID: String
    public let monitorName: String
    public let serialNumber: String
    public let modeNumber: Int
    public let modeName: String
    public let badge: String
    public let remainingMinutes: Int64?
    public let intervalMinutes: Int64?
    public let calibrationID: String?

    public var id: String { "\(monitorID)/\(modeNumber)" }

    public var remainingText: String {
        guard let remainingMinutes else { return "不明" }
        let magnitude = remainingMinutes.magnitude
        let hours = magnitude / 60 + (magnitude % 60 >= 30 ? 1 : 0)
        let duration = "約 \(hours)時間"
        return remainingMinutes < 0 ? "\(duration)超過" : duration
    }
}

public struct ReminderMonitorGroup: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let report: MonitorUsageReport?
    public let message: String?
    public let detail: String?
    public let lastSuccessAt: Date?
    public let isStale: Bool
    public let rows: [ReminderMenuRow]
}

/// A presentation-only snapshot. Constructing or opening a menu never starts a read.
public struct ReminderMenuData: Sendable {
    public let rows: [ReminderMenuRow]
    public let monitorIDs: [String]
    public let issue: String?
    public let groups: [ReminderMonitorGroup]

    public init(reports: [MonitorUsageReport]) {
        self.init(monitors: reports.map(MonitorDisplayState.current))
    }

    public init(monitors: [MonitorDisplayState]) {
        let reports = monitors.compactMap(\.report)
        monitorIDs = monitors.map(\.id).sorted()
        rows = reports.flatMap { report -> [ReminderMenuRow] in
            let history = report.calibrationHistory
            let interval = history.managementPolicy?.intervalHours.flatMap { hours -> Int64? in
                let (minutes, overflow) = Int64(hours).multipliedReportingOverflow(by: 60)
                return hours > 0 && !overflow ? minutes : nil
            }
            return history.colorModes.map { mode in
                let countdown = report.calibrationCountdown.colorModes.first { $0.modeNumber == mode.modeNumber }
                let name = mode.modeName ?? (mode.modeType == "Standard" ? mode.targetName : nil)
                let badge = mode.modeType == "Standard" ? "STD" : mode.modeType == "Calibration" ? "ADV" : "—"
                return ReminderMenuRow(
                    monitorID: report.monitor.identity.id,
                    monitorName: report.monitor.model.replacingOccurrences(of: "ColorEdge ", with: ""),
                    serialNumber: report.monitor.serialNumber, modeNumber: mode.modeNumber,
                    modeName: name ?? "モード \(mode.modeNumber)", badge: badge,
                    remainingMinutes: countdown?.remainingMinutes, intervalMinutes: interval,
                    calibrationID: mode.lastCalibration?.resultID
                )
            }
        }.sorted { lhs, rhs in
            switch (lhs.remainingMinutes, rhs.remainingMinutes) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.monitorID != rhs.monitorID { return lhs.monitorID < rhs.monitorID }
                return lhs.modeNumber < rhs.modeNumber
            }
        }
        let issues = monitors.compactMap(\.message)
        let unique = issues.reduce(into: [String]()) { result, issue in
            if !result.contains(issue) { result.append(issue) }
        }
        issue = unique.isEmpty ? nil : unique.joined(separator: "／")
        let sortedRows = rows
        let identities = monitorIDs
        groups = monitors.map { state in
            let id = state.id
            let name = state.identity.model?.replacingOccurrences(of: "ColorEdge ", with: "") ?? "モニター"
            let number = (identities.firstIndex(of: id) ?? 0) + 1
            return ReminderMonitorGroup(id: id, title: identities.count > 1 ? "\(name)・\(number)" : name,
                report: state.report, message: state.message, detail: state.detail,
                lastSuccessAt: state.lastSuccessAt, isStale: state.isStale,
                rows: sortedRows.filter { $0.monitorID == id })
        }.sorted { lhs, rhs in
            switch (lhs.rows.first?.remainingMinutes, rhs.rows.first?.remainingMinutes) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    public func monitorLabel(for row: ReminderMenuRow) -> String? {
        guard monitorIDs.count > 1, let index = monitorIDs.firstIndex(of: row.monitorID) else { return nil }
        return "\(row.monitorName)・\(index + 1)"
    }

}
