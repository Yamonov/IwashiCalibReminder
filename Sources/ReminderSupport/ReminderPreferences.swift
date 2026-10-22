import Foundation
import Observation

public enum ReminderUnit: String, CaseIterable, Sendable {
    case hours, days
    public var title: String { self == .hours ? L10n.text("hours") : L10n.text("days") }
    public var minutes: Double { self == .hours ? 60 : 24 * 60 }
}

@Observable @MainActor
public final class ReminderPreferences {
    public private(set) var thresholdValue: Double
    public private(set) var unit: ReminderUnit
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedUnit = ReminderUnit(rawValue: defaults.string(forKey: "reminderUnit") ?? "") ?? .hours
        let savedValue = defaults.object(forKey: "reminderValue") as? Double ?? 24
        if Self.isValid(value: savedValue, unit: savedUnit) {
            thresholdValue = savedValue; unit = savedUnit
        } else {
            thresholdValue = 24; unit = .hours
        }
    }

    public var thresholdMinutes: Int64 { Int64(thresholdValue * unit.minutes) }

    public static func isValid(value: Double, unit: ReminderUnit) -> Bool {
        value.isFinite && value >= 0 && value * unit.minutes < Double(Int64.max)
    }

    @discardableResult
    public func setThreshold(value: Double, unit: ReminderUnit) -> Bool {
        guard Self.isValid(value: value, unit: unit) else { return false }
        thresholdValue = value
        self.unit = unit
        defaults.set(value, forKey: "reminderValue")
        defaults.set(unit.rawValue, forKey: "reminderUnit")
        return true
    }

}

/// Decisions are independent of the macOS permission dialog and delivery API.
/// A delivery key is acknowledged only after the notification request succeeds.
public enum ReminderNotificationRules {
    public static func key(for row: ReminderMenuRow) -> String? {
        guard let calibration = row.calibrationID else { return nil }
        return [row.monitorName, row.serialNumber, String(row.modeNumber), calibration].joined(separator: "|")
    }

    public static func pending(menu: ReminderMenuData, thresholdMinutes: Int64,
                               deliveredKeys: Set<String>) -> [ReminderMenuRow] {
        let previousMonitors = Set(menu.groups.filter(\.isShowingPrevious).map(\.id))
        return menu.rows.filter {
            guard !previousMonitors.contains($0.monitorID) else { return false }
            guard let remaining = $0.remainingMinutes, remaining <= thresholdMinutes,
                  let key = key(for: $0) else { return false }
            return !deliveredKeys.contains(key)
        }
    }
}
