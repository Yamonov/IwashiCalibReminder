import EIZOHID
import Foundation

/// Keep only the previous graph's inputs, rather than a second copy of the DB/LUT data.
public struct MonitorGraphValue: Sendable {
    public let remainingMinutes: Int64
    public let intervalMinutes: Int64

    public init?(report: MonitorUsageReport) {
        guard let remaining = report.calibrationCountdown.earliest?.remainingMinutes,
              let hours = report.calibrationHistory.managementPolicy?.intervalHours, hours > 0 else { return nil }
        let (interval, overflow) = Int64(hours).multipliedReportingOverflow(by: 60)
        guard !overflow else { return nil }
        remainingMinutes = remaining
        intervalMinutes = interval
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
    public var id: String { identity.id }

    public init(identity: MonitorIdentity, report: MonitorUsageReport? = nil,
                graphValue: MonitorGraphValue? = nil, isStale: Bool = false,
                message: String? = nil, detail: String? = nil, lastSuccessAt: Date? = nil) {
        self.identity = identity
        self.report = report
        self.graphValue = graphValue
        self.isStale = isStale
        self.message = message
        self.detail = detail
        self.lastSuccessAt = lastSuccessAt
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
        case .cnInUse: "ColorNavigator 7の画面を閉じてから更新してください"
        case .cnStateUnknown: "ColorNavigator 7の起動状態を判定できません"
        case .notFound: "対象モニターを検出できません"
        case .noRegisteredMonitors: "ColorNavigatorに登録済みのモニターがありません"
        case .communication: "モニターとの通信に失敗しました"
        case .unsupported: "このモニターの通信形式には未対応です"
        case .invalidResponse: "モニターの応答を解釈できません"
        case .databaseUnavailable: "ColorNavigatorのDBを読み取れません"
        case .helper: "読み取り処理に失敗しました"
        }
    }
}
