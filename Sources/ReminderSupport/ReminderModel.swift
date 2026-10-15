import EIZOHID
import Foundation
import Observation

@Observable @MainActor
public final class ReminderModel {
    public enum Phase: Equatable { case idle, loading, ready, blocked, failed }
    public private(set) var phase: Phase = .idle
    public private(set) var reports: [MonitorUsageReport] = []
    public private(set) var message: String?
    public private(set) var attemptedAt: Date?
    public private(set) var updatedAt: Date?
    public let isDemo: Bool

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let reader: @Sendable () async throws -> [MonitorUsageReport]
    @ObservationIgnored private let accessCheck: @MainActor () -> ColorNavigatorAccessCheck
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored public var didRead: (@MainActor ([MonitorUsageReport]) -> Void)?

    public init(isDemo: Bool = false, refreshInterval: Duration = .seconds(3_600),
                reader: @escaping @Sendable () async throws -> [MonitorUsageReport] = {
                    try await HelperClient.bundled().read()
                },
                accessCheck: @escaping @MainActor () -> ColorNavigatorAccessCheck = { ColorNavigatorAccess.check() }) {
        self.isDemo = isDemo
        self.refreshInterval = refreshInterval
        self.reader = reader
        self.accessCheck = accessCheck
    }

    public var summary: ReminderSummary { ReminderSummary(reports: reports) }

    public var menuTitle: String {
        if isDemo { return "デモ " + (summary.remainingMinutes.map(ReminderText.menuTitle) ?? "—") }
        switch phase {
        case .idle, .loading: return "取得中…"
        case .blocked: return "CN使用中"
        case .failed: return "取得不可"
        case .ready: return summary.remainingMinutes.map(ReminderText.menuTitle) ?? "残り —"
        }
    }

    public var symbol: String {
        if phase == .blocked { return "pause.circle" }
        if phase == .failed { return "exclamationmark.triangle" }
        if let minutes = summary.remainingMinutes, minutes <= 0 { return "display.trianglebadge.exclamationmark" }
        return "display"
    }

    public func start() {
        guard timerTask == nil else { return }
        refresh()
        timerTask = Task { [weak self, refreshInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: refreshInterval) }
                catch { return }
                self?.refresh()
            }
        }
    }

    public func refresh() {
        guard refreshTask == nil else { return }
        attemptedAt = .now
        reports = []
        updatedAt = nil
        message = nil
        if !isDemo {
            let access = accessCheck()
            guard access.allowsMonitorAccess else {
                phase = .blocked
                message = access.state == "interfaceRunning"
                    ? "ColorNavigator 7の画面を閉じてから更新してください。メニューバーのAgentは起動したままで構いません。"
                    : "ColorNavigator 7の起動状態を判定できないため、取得を中止しました。"
                return
            }
        }
        phase = .loading
        refreshTask = Task { [weak self, reader, isDemo] in
            do {
                let result = try await (isDemo ? DemoData.reports() : reader())
                guard !Task.isCancelled, let self else { return }
                reports = result
                updatedAt = .now
                phase = .ready
                if result.isEmpty { message = "対象のモニターが接続されていません。" }
                didRead?(result)
            } catch {
                guard !Task.isCancelled, let self else { return }
                phase = .failed
                message = error.localizedDescription
            }
            self?.refreshTask = nil
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }
}
