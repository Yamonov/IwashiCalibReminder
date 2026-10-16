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

    public init(monitors: [MonitorDisplayState], thresholdMinutes: Int64) {
        segments = monitors.sorted { $0.id < $1.id }.map { monitor in
            Segment(id: monitor.id, graph: ReminderGraph(remainingMinutes: monitor.graphValue?.remainingMinutes,
                intervalMinutes: monitor.graphValue?.intervalMinutes, thresholdMinutes: thresholdMinutes),
                isStale: monitor.isStale)
        }
        earliest = segments.map(\.graph).filter { $0.remainingMinutes != nil }.min {
            ($0.remainingMinutes ?? .max) < ($1.remainingMinutes ?? .max)
        }
    }
}
