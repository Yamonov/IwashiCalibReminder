import Foundation

/// Calendar fields stored by CN in MonitorInformation.managementPolicy.schedule.
public struct CNCalibrationSchedule: Codable, Equatable, Sendable {
    public var type: String
    public var hour: Int?
    public var minute: Int?
    public var weekday: String?
    public var thWeek: Int?
    public var month: Int?
    public var monthOfQuarterly: String?
    public var monthOfSemiAnnual: String?
    public var intervalWeek: Int?
    public var intervalMonth: Int?

    public init(type: String, hour: Int? = nil, minute: Int? = nil, weekday: String? = nil,
                thWeek: Int? = nil, month: Int? = nil, monthOfQuarterly: String? = nil,
                monthOfSemiAnnual: String? = nil, intervalWeek: Int? = nil, intervalMonth: Int? = nil) {
        self.type = type; self.hour = hour; self.minute = minute; self.weekday = weekday
        self.thWeek = thWeek; self.month = month; self.monthOfQuarterly = monthOfQuarterly
        self.monthOfSemiAnnual = monthOfSemiAnnual; self.intervalWeek = intervalWeek; self.intervalMonth = intervalMonth
    }

    public var isCalendar: Bool { Self.calendarTypes.contains(type) }
    public static let calendarTypes: Set<String> = ["Daily", "Weekly", "Monthly", "Quarterly", "SemiAnnual", "Annual"]

    /// The first scheduled occurrence after the last successful calibration stays
    /// the deadline even after it has passed; opening a menu never postpones it.
    public func nextDate(after baseline: Date, timeZone: TimeZone = .current) -> Date? {
        guard let hour, (0...23).contains(hour), let minute, (0...59).contains(minute), isCalendar else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 1
        var time = DateComponents(hour: hour, minute: minute, second: 0)
        if type == "Daily" {
            return calendar.nextDate(after: baseline, matching: time, matchingPolicy: .nextTime,
                                     repeatedTimePolicy: .first)
        }
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        guard let weekday, let index = weekdays.firstIndex(of: weekday) else { return nil }
        let weekdayNumber = index + 1
        if type == "Weekly" {
            time.weekday = weekdayNumber
            if let intervalWeek {
                guard (1...52).contains(intervalWeek), let start = calendar.dateInterval(of: .weekOfYear, for: baseline)?.start,
                      let week = calendar.date(byAdding: .weekOfYear, value: intervalWeek, to: start) else { return nil }
                return calendar.nextDate(after: week.addingTimeInterval(-1), matching: time,
                                         matchingPolicy: .nextTime, repeatedTimePolicy: .first)
            }
            return calendar.nextDate(after: baseline, matching: time, matchingPolicy: .nextTime,
                                     repeatedTimePolicy: .first)
        }
        guard let thWeek, (1...5).contains(thWeek),
              let start = calendar.dateInterval(of: .month, for: baseline)?.start else { return nil }
        let months: Set<Int>
        switch type {
        case "Monthly": months = Set(1...12)
        case "Annual":
            guard let month, (1...12).contains(month) else { return nil }
            months = [month]
        case "Quarterly":
            guard let set = Self.months(monthOfQuarterly), set.count == 4,
                  let first = set.min(), first <= 3, set == Set(stride(from: first, through: 12, by: 3)) else { return nil }
            months = set
        case "SemiAnnual":
            guard let set = Self.months(monthOfSemiAnnual), set.count == 2,
                  let first = set.min(), first <= 6, set == [first, first + 6] else { return nil }
            months = set
        default: return nil
        }
        let step = type == "Monthly" ? (intervalMonth ?? 1) : 1
        guard (1...12).contains(step) else { return nil }
        let initial = type == "Monthly" && intervalMonth != nil ? step : 0
        // CN numbers Sunday-based calendar weeks, including a partial first week.
        // EIZO specifies week 1 -> 2 and week 5 -> 4 if the weekday is absent.
        // https://www.eizo.co.jp/support/db/files/manuals/ColorEdge/CG2400S-ja/ja-JP/247714571.html
        for offset in stride(from: initial, through: 120, by: step) {
            guard let candidateMonth = calendar.date(byAdding: .month, value: offset, to: start) else { return nil }
            guard months.contains(calendar.component(.month, from: candidateMonth)) else { continue }
            let firstWeekday = calendar.component(.weekday, from: candidateMonth)
            guard let days = calendar.range(of: .day, in: .month, for: candidateMonth) else { return nil }
            var day = 1 + weekdayNumber - firstWeekday + (thWeek - 1) * 7
            if day < 1 { day += 7 }
            if day >= days.upperBound { day -= 7 }
            guard days.contains(day),
                  let dayStart = calendar.date(byAdding: .day, value: day - 1, to: candidateMonth),
                  let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart,
                                           matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                  date > baseline else { continue }
            return date
        }
        return nil
    }

    private static func months(_ text: String?) -> Set<Int>? {
        guard let text else { return nil }
        let parts = text.split(separator: "_", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ (1...12).contains($0) }),
              Set(numbers).count == numbers.count else { return nil }
        return Set(numbers)
    }
}

public enum CNDate {
    public static func local(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        guard text.count == 19, let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    public static func iso(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
}
