import EIZOHID
import Foundation

public struct MonitorInformationValue: Sendable {
    public let usageMinutes: Int64
    public let policy: CNManagementPolicy?
    public let commonSettings: CNCommonSettings?
    public init(report: MonitorUsageReport) {
        usageMinutes = Int64(report.monitor.usageHours) * 60 + Int64(report.monitor.usageMinutes)
        policy = report.calibrationHistory.managementPolicy
        commonSettings = report.calibrationHistory.commonSettings
    }
}

/// Keep only the previous graph's inputs, rather than a second copy of the DB/LUT data.
public struct MonitorGraphValue: Sendable {
    public let remainingMinutes: Int64
    public let intervalMinutes: Int64
    public let nextCalibrationDate: String?

    public init?(report: MonitorUsageReport) {
        guard let earliest = report.calibrationCountdown.earliest,
              let mode = report.calibrationCountdown.colorModes.first(where: { $0.modeNumber == earliest.modes.first?.modeNumber }) else { return nil }
        let remaining = earliest.remainingMinutes
        let interval: Int64
        if let minutes = mode.intervalMinutes, minutes > 0 { interval = minutes }
        else {
            guard let hours = report.calibrationHistory.managementPolicy?.intervalHours, hours > 0 else { return nil }
            let (minutes, overflow) = Int64(hours).multipliedReportingOverflow(by: 60)
            guard !overflow else { return nil }
            interval = minutes
        }
        remainingMinutes = remaining
        intervalMinutes = interval
        nextCalibrationDate = mode.nextCalibrationDate
    }
}

public struct MonitorDisplayState: Sendable, Identifiable {
    public let identity: MonitorIdentity
    public let report: MonitorUsageReport?
    public let graphValue: MonitorGraphValue?
    public let isStale: Bool
    public let message: String?
    public let detail: String?
    public let lastSuccessAt: Date?
    /// Display-only rows from a previous complete reading, never notification input.
    public let previousRows: [ReminderMenuRow]?
    public let previousInformation: MonitorInformationValue?
    public var isShowingPrevious: Bool { previousRows != nil }
    public var id: String { identity.id }

    public init(identity: MonitorIdentity, report: MonitorUsageReport? = nil,
                graphValue: MonitorGraphValue? = nil, isStale: Bool = false,
                message: String? = nil, detail: String? = nil, lastSuccessAt: Date? = nil,
                previousRows: [ReminderMenuRow]? = nil, previousInformation: MonitorInformationValue? = nil) {
        self.identity = identity
        self.report = report
        self.graphValue = graphValue
        self.isStale = isStale
        self.message = message
        self.detail = detail
        self.lastSuccessAt = lastSuccessAt
        self.previousRows = previousRows
        self.previousInformation = previousInformation
    }

    public static func current(_ report: MonitorUsageReport) -> MonitorDisplayState {
        MonitorDisplayState(identity: report.monitor.identity, report: report,
                            graphValue: MonitorGraphValue(report: report),
                            message: ReminderText.unavailable(report))
    }
}

extension AcquisitionFailure {
    public var displayMessage: String {
        switch kind {
        case .cnInUse: L10n.text("Close ColorNavigator 7 windows, then refresh")
        case .cnStateUnknown: L10n.text("Unable to determine the ColorNavigator 7 state")
        case .notFound: L10n.text("No matching monitor found")
        case .noRegisteredMonitors: L10n.text("No monitors are registered in ColorNavigator")
        case .communication: L10n.text("Unable to communicate with the monitor")
        case .unsupported: L10n.text("This monitor communication format is not supported")
        case .invalidResponse: L10n.text("Unable to interpret the monitor response")
        case .databaseUnavailable: L10n.text("Unable to read the ColorNavigator database")
        case .helper: L10n.text("Unable to acquire monitor information")
        case .readerBusy: L10n.text("Another reading is in progress")
        }
    }
}
