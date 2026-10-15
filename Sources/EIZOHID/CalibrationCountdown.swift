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
                                 history: CNCalibrationHistory) -> CNCalibrationCountdown {
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
        // Validation/correction/self-calibration schedules can use different baselines.
        guard policy.type == "CNCalibration", policy.scheduleType == "EveryUsageTime" else {
            return unavailable("unsupportedSchedule", "Requires CNCalibration with an EveryUsageTime schedule")
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
                                status: status, message: message, elapsedMinutes: elapsed, remainingMinutes: remaining)
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
            return result(deadlineStatus(remaining), elapsed: elapsed, remaining: remaining)
        }
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

    public init(monitor: MonitorReading, calibrationHistory: CNCalibrationHistory, includeAllModes: Bool = false) {
        self.monitor = monitor
        self.calibrationHistory = calibrationHistory.selectingModes(using: monitor.modeAvailability, includeAllModes: includeAllModes)
        calibrationCountdown = .calculate(currentHours: monitor.usageHours, currentMinutes: monitor.usageMinutes,
                                          history: self.calibrationHistory)
    }

    enum CodingKeys: String, CodingKey { case calibrationHistory, calibrationCountdown }
    public init(from decoder: any Decoder) throws {
        monitor = try MonitorReading(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        calibrationHistory = try values.decode(CNCalibrationHistory.self, forKey: .calibrationHistory)
        calibrationCountdown = try values.decode(CNCalibrationCountdown.self, forKey: .calibrationCountdown)
    }

    public func encode(to encoder: any Encoder) throws {
        try monitor.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(calibrationHistory, forKey: .calibrationHistory)
        try values.encode(calibrationCountdown, forKey: .calibrationCountdown)
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
