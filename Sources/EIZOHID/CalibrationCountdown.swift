import Foundation

public struct CNDeadlineMode: Codable, Sendable {
    public let modeNumber: Int
    public let modeName: String?
    public let targetName: String?
}

public struct CNModeCountdown: Codable, Sendable {
    public let modeNumber: Int
    public let modeName: String?
    public let targetName: String?
    public let status: String
    public let message: String?
    public let elapsedMinutes: Int64?
    /// Signed: zero means due now, a negative value means overdue.
    public let remainingMinutes: Int64?
    public var nextCalibrationDate: String? = nil
    public var intervalMinutes: Int64? = nil
    public var basis: String? = nil
    /// Usage-based forecast calculated at acquisition, separate from a fixed calendar deadline.
    public var predictedCalibrationDate: String? = nil

    public func remaining(at date: Date) -> Int64? {
        guard basis == "calendar", let nextCalibrationDate, let deadline = CNDate.iso(nextCalibrationDate) else {
            return remainingMinutes
        }
        return Int64(floor(deadline.timeIntervalSince(date) / 60))
    }
}

public struct CNEarliestCalibrationDeadline: Codable, Sendable {
    public let remainingMinutes: Int64
    public let status: String
    public let modes: [CNDeadlineMode]
}

public struct CNCalibrationCountdown: Codable, Sendable {
    public let status: String
    public let message: String?
    public let colorModes: [CNModeCountdown]
    public let earliest: CNEarliestCalibrationDeadline?

    public static func calculate(currentHours: UInt32, currentMinutes: UInt8,
                                 history: CNCalibrationHistory, currentDate: Date? = .now,
                                 timeZone: TimeZone = .current) -> CNCalibrationCountdown {
        func unavailable(_ status: String, _ message: String) -> CNCalibrationCountdown {
            CNCalibrationCountdown(status: status, message: message, colorModes: [], earliest: nil)
        }
        guard history.status == "available" else {
            return unavailable("historyUnavailable", "CN calibration history is \(history.status)")
        }
        guard let policy = history.managementPolicy else {
            return unavailable("scheduleUnavailable", "CN management policy is not recorded")
        }
        guard policy.type != "None" else {
            return unavailable("disabled", "CN calibration scheduling is disabled")
        }
        // Validation and SelfCorrection use different baselines.
        guard policy.type == "CNCalibration" || policy.type == "SelfCalibration" else {
            return unavailable("unsupportedSchedule", "Requires a calibration schedule")
        }
        if let schedule = policy.calendarSchedule, schedule.isCalendar {
            return calendarCountdown(currentHours: currentHours, currentMinutes: currentMinutes,
                history: history, schedule: schedule, currentDate: currentDate, timeZone: timeZone)
        }
        guard policy.scheduleType == "EveryUsageTime" else {
            return unavailable("unsupportedSchedule", "Calendar schedule fields are unavailable or unsupported")
        }
        guard let interval = policy.intervalHours, interval > 0 else {
            return unavailable("scheduleUnavailable", "A positive calibration interval is not recorded")
        }
        let (intervalMinutes, overflow) = Int64(interval).multipliedReportingOverflow(by: 60)
        guard !overflow else { return unavailable("invalidInterval", "Calibration interval is too large") }
        guard currentMinutes < 60 else {
            return unavailable("invalidCurrentUsage", "Current usage minutes must be less than 60")
        }
        let current = Int64(currentHours) * 60 + Int64(currentMinutes)
        let modes = history.colorModes.map { mode -> CNModeCountdown in
            // Standard-mode target names are their fixed names in the CN database.
            // A calibration target name need not equal the monitor's mode name.
            let name = mode.modeName ?? (mode.modeType == "Standard" ? mode.targetName : nil)
            func result(_ status: String, message: String? = nil, elapsed: Int64? = nil,
                        remaining: Int64? = nil) -> CNModeCountdown {
                CNModeCountdown(modeNumber: mode.modeNumber, modeName: name, targetName: mode.targetName,
                                status: status, message: message, elapsedMinutes: elapsed, remainingMinutes: remaining,
                                intervalMinutes: intervalMinutes, basis: "usage")
            }
            guard mode.targetID != nil else { return result("unassigned", message: "No target assigned") }
            guard mode.status == "available" || mode.status == "incompleteCalibration" else {
                return result("historyUnavailable", message: "Calibration record is \(mode.status)")
            }
            guard let baseline = mode.lastCalibration, let hours = baseline.usageHours,
                  let minutes = baseline.usageMinutes, minutes < 60 else {
                return result("usageAtCalibrationUnavailable", message: "Usage time at calibration is not fully recorded")
            }
            let calibratedAt = Int64(hours) * 60 + Int64(minutes)
            guard current >= calibratedAt else {
                return result("usageCounterBeforeCalibration", message: "Current usage is less than usage at calibration")
            }
            let elapsed = current - calibratedAt
            let remaining = intervalMinutes - elapsed
            var countdown = result(deadlineStatus(remaining), elapsed: elapsed, remaining: remaining)
            countdown.predictedCalibrationDate = predictUsageDate(
                calibrationDate: baseline.executedDate, readAt: currentDate,
                elapsedUsageMinutes: elapsed, remainingUsageMinutes: remaining, timeZone: timeZone)
            return countdown
        }
        return summarize(modes)
    }

    private static func predictUsageDate(calibrationDate: String?, readAt: Date?,
                                         elapsedUsageMinutes: Int64, remainingUsageMinutes: Int64,
                                         timeZone: TimeZone) -> String? {
        guard elapsedUsageMinutes > 0, remainingUsageMinutes >= 0,
              let readAt, let calibrationDate,
              let baseline = CNDate.local(calibrationDate, timeZone: timeZone) else { return nil }
        let elapsedSeconds = readAt.timeIntervalSince(baseline)
        let usedSeconds = Double(elapsedUsageMinutes) * 60
        guard elapsedSeconds.isFinite, elapsedSeconds > 0, usedSeconds <= elapsedSeconds else { return nil }
        // Observed duty cycle = used time / wall-clock time since calibration.
        // Keep minute-precision usage counters; only the displayed hours are rounded.
        let timeToDeadline = Double(remainingUsageMinutes) / Double(elapsedUsageMinutes) * elapsedSeconds
        let timestamp = readAt.timeIntervalSince1970 + timeToDeadline
        guard timestamp.isFinite, timestamp >= -62_135_596_800, timestamp <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: timestamp).ISO8601Format()
    }

    private static func calendarCountdown(currentHours: UInt32, currentMinutes: UInt8,
                                          history: CNCalibrationHistory, schedule: CNCalibrationSchedule,
                                          currentDate: Date?, timeZone: TimeZone) -> CNCalibrationCountdown {
        guard let currentDate else {
            return CNCalibrationCountdown(status: "invalidCurrentDate", message: "Reading date is unavailable",
                                          colorModes: [], earliest: nil)
        }
        let usage = Int64(currentHours) * 60 + Int64(currentMinutes)
        let modes = history.colorModes.map { mode -> CNModeCountdown in
            let name = mode.modeName ?? (mode.modeType == "Standard" ? mode.targetName : nil)
            func unavailable(_ status: String) -> CNModeCountdown {
                CNModeCountdown(modeNumber: mode.modeNumber, modeName: name, targetName: mode.targetName,
                    status: status, message: nil, elapsedMinutes: nil, remainingMinutes: nil, basis: "calendar")
            }
            guard mode.targetID != nil else { return unavailable("unassigned") }
            guard mode.status == "available" || mode.status == "incompleteCalibration", let record = mode.lastCalibration,
                  let text = record.executedDate, let baseline = CNDate.local(text, timeZone: timeZone) else {
                return unavailable("calibrationDateUnavailable")
            }
            guard baseline <= currentDate else { return unavailable("calibrationDateInFuture") }
            guard let deadline = schedule.nextDate(after: baseline, timeZone: timeZone) else {
                return unavailable("invalidSchedule")
            }
            var elapsed: Int64?
            if currentMinutes < 60, let hours = record.usageHours, let minutes = record.usageMinutes, minutes < 60 {
                let previous = Int64(hours) * 60 + Int64(minutes)
                if usage >= previous { elapsed = usage - previous }
            }
            let remaining = Int64(floor(deadline.timeIntervalSince(currentDate) / 60))
            let interval = Int64(ceil(deadline.timeIntervalSince(baseline) / 60))
            return CNModeCountdown(modeNumber: mode.modeNumber, modeName: name, targetName: mode.targetName,
                status: deadlineStatus(remaining), message: nil, elapsedMinutes: elapsed, remainingMinutes: remaining,
                nextCalibrationDate: deadline.ISO8601Format(), intervalMinutes: interval, basis: "calendar")
        }
        return summarize(modes)
    }

    private static func summarize(_ modes: [CNModeCountdown]) -> CNCalibrationCountdown {
        guard let minimum = modes.compactMap(\.remainingMinutes).min() else {
            return CNCalibrationCountdown(status: "noCalculableModes", message: "No mode has a usable calibration baseline",
                                          colorModes: modes, earliest: nil)
        }
        let earliestModes = modes.filter { $0.remainingMinutes == minimum }.map {
            CNDeadlineMode(modeNumber: $0.modeNumber, modeName: $0.modeName, targetName: $0.targetName)
        }.sorted { $0.modeNumber < $1.modeNumber }
        let incomplete = modes.contains { $0.status != "unassigned" && $0.remainingMinutes == nil }
        return CNCalibrationCountdown(
            status: incomplete ? "partiallyAvailable" : "available",
            message: incomplete ? "Earliest deadline is among modes with calculable usage time only" : nil,
            colorModes: modes,
            earliest: CNEarliestCalibrationDeadline(remainingMinutes: minimum, status: deadlineStatus(minimum), modes: earliestModes)
        )
    }

    private static func deadlineStatus(_ remaining: Int64) -> String {
        remaining > 0 ? "remaining" : remaining == 0 ? "due" : "overdue"
    }
}

/// Keeps the existing flat HID JSON fields and adds CN history and its derived countdown.
public struct MonitorUsageReport: Codable, Sendable {
    public let monitor: MonitorReading
    public let calibrationHistory: CNCalibrationHistory
    public let calibrationCountdown: CNCalibrationCountdown
    public let calibrationConfiguration: CNCalibrationConfiguration?

    public init(monitor: MonitorReading, calibrationHistory: CNCalibrationHistory, includeAllModes: Bool = false) {
        self.monitor = monitor
        calibrationConfiguration = CNCalibrationConfiguration(history: calibrationHistory)
        self.calibrationHistory = calibrationHistory.selectingModes(using: monitor.modeAvailability, includeAllModes: includeAllModes)
        calibrationCountdown = .calculate(currentHours: monitor.usageHours, currentMinutes: monitor.usageMinutes,
                                          history: self.calibrationHistory, currentDate: CNDate.iso(monitor.readAt))
    }

    enum CodingKeys: String, CodingKey { case calibrationHistory, calibrationCountdown, calibrationConfiguration }
    public init(from decoder: any Decoder) throws {
        monitor = try MonitorReading(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        calibrationHistory = try values.decode(CNCalibrationHistory.self, forKey: .calibrationHistory)
        calibrationCountdown = try values.decode(CNCalibrationCountdown.self, forKey: .calibrationCountdown)
        calibrationConfiguration = try values.decodeIfPresent(CNCalibrationConfiguration.self, forKey: .calibrationConfiguration)
    }

    public func encode(to encoder: any Encoder) throws {
        try monitor.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(calibrationHistory, forKey: .calibrationHistory)
        try values.encode(calibrationCountdown, forKey: .calibrationCountdown)
        try values.encodeIfPresent(calibrationConfiguration, forKey: .calibrationConfiguration)
    }
}

public enum CalibrationCountdownText {
    public static func remaining(_ minutes: Int64) -> String {
        let magnitude = minutes.magnitude
        let duration = "\(magnitude / 60) hours \(magnitude % 60) minutes"
        if minutes < 0 { return "overdue by \(duration)" }
        if minutes == 0 { return "due now (0 hours 0 minutes remaining)" }
        return "\(duration) remaining"
    }

    public static func earliest(_ countdown: CNCalibrationCountdown) -> String {
        guard let earliest = countdown.earliest else {
            return "Earliest calibration deadline: unavailable (\(countdown.message ?? countdown.status))"
        }
        let names = earliest.modes.map {
            "\($0.modeNumber): \($0.modeName ?? "mode name not recorded")"
        }.joined(separator: ", ")
        let scope = countdown.status == "partiallyAvailable" ? " (among modes with sufficient data)" : ""
        return "Earliest calibration deadline\(scope): \(remaining(earliest.remainingMinutes))\n  Modes: \(names)"
    }
}
