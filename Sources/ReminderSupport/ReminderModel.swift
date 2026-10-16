import EIZOHID
import Foundation
import Observation

@Observable @MainActor
public final class ReminderModel {
    public enum Phase: Equatable { case idle, loading, ready, blocked, failed }
    public enum RefreshReason: String, Sendable { case startup, scheduled, manual }
    public private(set) var phase: Phase = .idle
    public private(set) var reports: [MonitorUsageReport] = []
    public private(set) var monitors: [MonitorDisplayState] = []
    public private(set) var globalMessages: [String] = []
    public private(set) var message: String?
    public private(set) var attemptedAt: Date?
    public private(set) var updatedAt: Date?
    public let isDemo: Bool

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let reader: @Sendable (String) async throws -> MonitorRefreshResult
    @ObservationIgnored private let diagnostics: DiagnosticLog?
    @ObservationIgnored private var saved: [String: SavedMonitor] = [:]
    @ObservationIgnored private let accessCheck: @MainActor () -> ColorNavigatorAccessCheck
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored public var didRead: (@MainActor ([MonitorUsageReport]) -> Void)?

    public init(isDemo: Bool = false, refreshInterval: Duration = .seconds(3_600),
                reader: (@Sendable () async throws -> [MonitorUsageReport])? = nil,
                snapshotReader: @escaping @Sendable (String) async throws -> MonitorRefreshResult = {
                    try await HelperClient.bundled().readSnapshot(refreshID: $0)
                }, diagnostics: DiagnosticLog? = nil,
                accessCheck: @escaping @MainActor () -> ColorNavigatorAccessCheck = { ColorNavigatorAccess.check() }) {
        self.isDemo = isDemo
        self.refreshInterval = refreshInterval
        if let reader { self.reader = { _ in MonitorRefreshResult(reports: try await reader()) } }
        else { self.reader = snapshotReader }
        self.diagnostics = diagnostics
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
        refresh(reason: .startup)
        timerTask = Task.detached(priority: .utility) { [weak self, refreshInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: refreshInterval) }
                catch { return }
                await self?.refresh(reason: .scheduled)
            }
        }
    }

    public func refresh(reason: RefreshReason = .manual) {
        guard !Task.isCancelled, refreshTask == nil else { return }
        attemptedAt = .now
        message = nil
        let identifier = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        diagnostics?.record(DiagnosticEvent("refresh.started", fields: [
            "refreshID": identifier, "reason": reason.rawValue,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""], level: .debug))
        if !isDemo {
            let access = accessCheck()
            guard access.allowsMonitorAccess else {
                let failure = AcquisitionFailure(access.state == "interfaceRunning" ? .cnInUse : .cnStateUnknown,
                                                 detail: access.message, operation: "checkCN")
                apply(MonitorRefreshResult(globalFailures: [failure]))
                logCompletion(identifier, started: started, failures: [failure])
                return
            }
        }
        phase = .loading
        // Keep the previous presentation while refreshing; there is no extra read or retry.
        globalMessages = ["情報を取得中…"]
        // Keep I/O outside the UI actor and cross back explicitly for publication.
        // The production default reader must follow the same path as injected readers.
        refreshTask = Task.detached(priority: .utility) { [weak self, reader, isDemo] in
            let result: MonitorRefreshResult
            do {
                if isDemo {
                    result = MonitorRefreshResult(reports: try DemoData.reports())
                } else {
                    result = try await reader(identifier)
                }
            } catch {
                let failure = AcquisitionFailure(.helper, detail: error.localizedDescription, operation: "runHelper")
                result = MonitorRefreshResult(globalFailures: [failure])
            }
            guard !Task.isCancelled else { return }
            await self?.finishRefresh(result, identifier: identifier, started: started)
        }
    }

    private func finishRefresh(_ result: MonitorRefreshResult, identifier: String, started: TimeInterval) {
        guard !Task.isCancelled else { return }
        defer { refreshTask = nil }
        apply(result)
        logCompletion(identifier, started: started, failures: result.globalFailures)
        if !reports.isEmpty { didRead?(reports) }
    }

    private struct SavedMonitor {
        let identity: MonitorIdentity
        var graph: MonitorGraphValue?
        var date: Date?
    }

    private func apply(_ result: MonitorRefreshResult) {
        if let registered = result.registeredMonitors {
            let allowed = Set(registered.map(\.id))
            saved = saved.filter { allowed.contains($0.key) }
        }
        reports = result.reports
        globalMessages = result.globalFailures.map(\.displayMessage)
        message = result.globalFailures.map(\.detail).joined(separator: "\n")
        let hasGlobalFailure = !result.globalFailures.isEmpty
        let onlyMissing = result.globalFailures.allSatisfy { $0.kind == .notFound }
        let sharedDBFailure = result.globalFailures.contains { $0.kind == .databaseUnavailable }
        var next: [MonitorDisplayState] = []
        for report in reports {
            let identity = report.monitor.identity
            // An earlier attempt may have failed before reading the identity. Merge
            // only within the same IOKit connection, never merely by USB port number.
            if let registry = identity.registryID {
                let aliases = saved.filter { $0.key != identity.id && $0.value.identity.model == nil
                    && $0.value.identity.registryID == registry }.map(\.key)
                aliases.forEach { saved.removeValue(forKey: $0) }
            }
            let value = MonitorGraphValue(report: report)
            let complete = report.calibrationCountdown.status == "available" && value != nil && !hasGlobalFailure
            let old = saved[identity.id]
            var previous = SavedMonitor(identity: identity, graph: old?.graph, date: old?.date)
            if complete {
                previous.graph = value
                previous.date = .now
                updatedAt = previous.date
            }
            saved[identity.id] = previous
            let issue = sharedDBFailure ? nil : ReminderText.unavailable(report)
            next.append(MonitorDisplayState(identity: identity, report: report,
                graphValue: complete ? value : previous.graph ?? value, isStale: !complete,
                message: issue, detail: report.calibrationHistory.message ?? report.calibrationCountdown.message,
                lastSuccessAt: previous.date))
        }
        for failed in result.failures {
            let previous = saved[failed.identity.id]
                ?? saved.values.first { failed.identity.registryID != nil && $0.identity.registryID == failed.identity.registryID }
            let identity = previous?.identity ?? failed.identity
            if saved[identity.id] == nil { saved[identity.id] = SavedMonitor(identity: identity) }
            next.append(MonitorDisplayState(identity: identity, graphValue: previous?.graph, isStale: true,
                message: failed.failure.displayMessage, detail: failed.failure.detail, lastSuccessAt: previous?.date))
        }
        let received = Set(next.map(\.id))
        for previous in saved.values where !received.contains(previous.identity.id) {
            next.append(MonitorDisplayState(identity: previous.identity, graphValue: previous.graph, isStale: true,
                message: !hasGlobalFailure || onlyMissing ? "モニターを検出できません" : nil,
                lastSuccessAt: previous.date))
        }
        if onlyMissing && !next.isEmpty { globalMessages = [] }
        if next.isEmpty && globalMessages.isEmpty { globalMessages = ["対象モニターがありません"] }
        monitors = next.sorted { $0.id < $1.id }
        if result.globalFailures.contains(where: { $0.kind == .cnInUse || $0.kind == .cnStateUnknown }) { phase = .blocked }
        else { phase = hasGlobalFailure || reports.isEmpty ? .failed : .ready }
    }

    private func logCompletion(_ identifier: String, started: TimeInterval, failures: [AcquisitionFailure]) {
        for failure in failures {
            diagnostics?.record(DiagnosticEvent("refresh.failure", fields: [
                "refreshID": identifier, "code": failure.kind.rawValue, "operation": failure.operation ?? "",
                "ioReturn": failure.ioReturn.map(String.init) ?? "", "detail": failure.detail], level: failure.diagnosticLevel))
        }
        diagnostics?.record(DiagnosticEvent("refresh.finished", fields: [
            "refreshID": identifier, "phase": String(describing: phase), "detail": message ?? "",
            "elapsedMilliseconds": String((ProcessInfo.processInfo.systemUptime - started) * 1000),
            "lastSuccessAt": updatedAt?.ISO8601Format() ?? "", "monitorCount": String(monitors.count)]))
        for monitor in monitors {
            diagnostics?.record(DiagnosticEvent("refresh.monitor", fields: [
                "refreshID": identifier, "model": monitor.identity.model ?? "", "serialNumber": monitor.identity.serialNumber ?? "",
                "locationID": monitor.identity.locationID, "stale": String(monitor.isStale),
                "message": monitor.message ?? "", "detail": monitor.detail ?? "",
                "historyStatus": monitor.report?.calibrationHistory.status ?? "unavailable",
                "countdownStatus": monitor.report?.calibrationCountdown.status ?? "unavailable",
                "lastSuccessAt": monitor.lastSuccessAt?.ISO8601Format() ?? ""], level: monitor.isStale ? .notice : .info))
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }
}
