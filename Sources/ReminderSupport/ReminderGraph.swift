import EIZOHID
import Foundation

/// Unrounded usage time determines color and height. The label alone uses whole hours.
public struct ReminderGraph: Equatable, Sendable {
    public enum Level: Sendable { case unknown, normal, caution, warning, overdue }

    public let level: Level
    public let fraction: Double?
    public let remainingMinutes: Int64?

    public var label: String? {
        guard let remainingMinutes, level != .unknown else { return nil }
        if level == .overdue { return "NG" }
        guard remainingMinutes < 100 * 60 else { return nil }
        return String(remainingMinutes / 60)
    }

    public init(menu: ReminderMenuData, thresholdMinutes: Int64) {
        let first = menu.rows.first { $0.remainingMinutes != nil }
        self.init(remainingMinutes: first?.remainingMinutes,
                  intervalMinutes: first?.intervalMinutes, thresholdMinutes: thresholdMinutes)
    }

    public init(remainingMinutes: Int64?, intervalMinutes: Int64?, thresholdMinutes: Int64) {
        self.remainingMinutes = remainingMinutes
        guard let remainingMinutes, let intervalMinutes, intervalMinutes > 0 else {
            level = .unknown
            fraction = nil
            return
        }
        if remainingMinutes < 0 {
            level = .overdue
            fraction = 1
            return
        }
        fraction = min(1, Double(remainingMinutes) / Double(intervalMinutes))
        let threshold = max(0, thresholdMinutes)
        let cautionThreshold = max(0, intervalMinutes - threshold) / 3
        if remainingMinutes <= threshold {
            level = .warning
        } else if remainingMinutes <= cautionThreshold {
            level = .caution
        } else {
            level = .normal
        }
    }
}

public struct ReminderStatusGraph: Sendable {
    public struct Segment: Sendable {
        public let id: String
        public let graph: ReminderGraph
        public let isStale: Bool
    }
    public let segments: [Segment]
    public let earliest: ReminderGraph?
    /// Next visible calendar-hour/color/deadline transition; usage-based and stale data do not tick.
    public let nextDisplayChange: Date?

    public init(monitors: [MonitorDisplayState], thresholdMinutes: Int64, at date: Date = .now) {
        var changes: [Date] = []
        segments = monitors.sorted { $0.id < $1.id }.map { monitor in
            let remaining: Int64?
            if !monitor.isStale, let deadline = monitor.graphValue?.nextCalibrationDate.flatMap(CNDate.iso) {
                let minutes = Int64(floor(deadline.timeIntervalSince(date) / 60))
                remaining = minutes
                if let interval = monitor.graphValue?.intervalMinutes,
                   let next = Self.nextChange(deadline: deadline, remaining: minutes, interval: interval,
                                              threshold: thresholdMinutes, after: date) { changes.append(next) }
            } else { remaining = monitor.graphValue?.remainingMinutes }
            return Segment(id: monitor.id, graph: ReminderGraph(remainingMinutes: remaining,
                intervalMinutes: monitor.graphValue?.intervalMinutes, thresholdMinutes: thresholdMinutes),
                isStale: monitor.isStale)
        }
        earliest = segments.map(\.graph).filter { $0.remainingMinutes != nil }.min {
            ($0.remainingMinutes ?? .max) < ($1.remainingMinutes ?? .max)
        }
        nextDisplayChange = changes.min()
    }

    private static func nextChange(deadline: Date, remaining: Int64, interval: Int64,
                                   threshold: Int64, after date: Date) -> Date? {
        guard remaining >= 0, interval > 0 else { return nil }
        let threshold = max(0, threshold)
        let caution = max(0, interval - threshold) / 3
        var candidates: [Date] = []
        // One second past each boundary avoids rescheduling the same boundary
        // when a timer fires exactly at a minute/hour represented by floor().
        let displayedHours = remaining >= 100 * 60 ? 100 : remaining / 60
        candidates.append(deadline.addingTimeInterval(-Double(displayedHours) * 3600 + 1))
        if remaining > threshold {
            candidates.append(deadline.addingTimeInterval(-(Double(threshold) + 1) * 60 + 1))
        }
        if caution > threshold && remaining > caution {
            candidates.append(deadline.addingTimeInterval(-(Double(caution) + 1) * 60 + 1))
        }
        return candidates.filter { $0 > date }.min()
    }
}
