import EIZOHID
import Foundation
import Observation

@Observable @MainActor
public final class ReminderModel {
    public enum Phase: Equatable { case idle, loading, ready, blocked, failed }
    public enum RefreshReason: String, Sendable { case startup, scheduled, manual, wake }
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
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var wakeGeneration: UUID?
    @ObservationIgnored private(set) var wakeRefreshPending = false
    @ObservationIgnored private let wakeWait: @Sendable () async throws -> Void
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
                accessCheck: @escaping @MainActor () -> ColorNavigatorAccessCheck = { ColorNavigatorAccess.check() },
                wakeWait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        self.isDemo = isDemo
        self.refreshInterval = refreshInterval
        if let reader { self.reader = { _ in MonitorRefreshResult(reports: try await reader()) } }
        else { self.reader = snapshotReader }
        self.diagnostics = diagnostics
        self.accessCheck = accessCheck
        self.wakeWait = wakeWait
    }

    public var summary: ReminderSummary { ReminderSummary(reports: reports) }

    public var menuTitle: String {
        if isDemo { return L10n.text("Demo %@", summary.remainingMinutes.map(ReminderText.menuTitle) ?? "—") }
        switch phase {
        case .idle, .loading: return L10n.text("Reading…")
        case .blocked: return L10n.text("CN in use")
        case .failed: return L10n.text("Unavailable")
        case .ready: return summary.remainingMinutes.map(ReminderText.menuTitle) ?? L10n.text("Remaining —")
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
                guard let model = self else { return }
                await model.refresh(reason: .scheduled)
            }
        }
    }

    public func refresh(reason: RefreshReason = .manual) {
        guard !Task.isCancelled, refreshTask == nil else { return }
        if reason == .scheduled, wakeTask != nil || wakeRefreshPending { return }
        if reason == .manual { cancelWakeRefresh() }
        attemptedAt = .now
        message = nil
        let identifier = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        diagnostics?.record(DiagnosticEvent("refresh.started", fields: [
            "refreshID": identifier, "reason": reason.rawValue,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""], level: .debug))
        if !isDemo {
            if let failure = accessCheck().denial {
                apply(MonitorRefreshResult(globalFailures: [failure]))
                logCompletion(identifier, started: started, failures: [failure])
                return
            }
        }
        phase = .loading
        // Retain the displayed reading until this explicit update completes.
        globalMessages = [L10n.text("Refreshing monitor information…")]
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

    /// Coalesce system-wake and display-wake notifications after the final event.
    public func refreshAfterWake() {
        cancelWakeRefresh()
        let generation = UUID()
        wakeGeneration = generation
        phase = .loading
        globalMessages = [L10n.text("Refreshing monitor information…")]
        wakeTask = Task.detached(priority: .utility) { [weak self, wakeWait] in
            do { try await wakeWait() }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.finishWakeDelay(generation)
        }
    }

    private func finishWakeDelay(_ generation: UUID) {
        guard wakeGeneration == generation else { return }
        wakeTask = nil
        wakeGeneration = nil
        if refreshTask != nil { wakeRefreshPending = true }
        else { refresh(reason: .wake) }
    }

    private func cancelWakeRefresh() {
        wakeTask?.cancel()
        wakeTask = nil
        wakeGeneration = nil
        wakeRefreshPending = false
    }

    private func finishRefresh(_ result: MonitorRefreshResult, identifier: String, started: TimeInterval) {
        guard !Task.isCancelled else { return }
        refreshTask = nil
        apply(result)
        logCompletion(identifier, started: started, failures: result.globalFailures)
        if wakeTask != nil {
            phase = .loading
            globalMessages = [L10n.text("Refreshing monitor information…")]
        } else if wakeRefreshPending {
            wakeRefreshPending = false
            refresh(reason: .wake)
        } else if !reports.isEmpty { didRead?(reports) }
    }

    private struct SavedMonitor {
        let identity: MonitorIdentity
        var graph: MonitorGraphValue?
        var rows: [ReminderMenuRow]?
        var information: MonitorInformationValue?
        var configuration: CNCalibrationConfiguration?
        var enabledModes: [Int]?
        var usageMinutes: UInt64?
        var date: Date?

        func permitsPreviousReading(for report: MonitorUsageReport) -> Bool {
            if let previous = configuration, let current = report.calibrationConfiguration, previous != current { return false }
            if let previous = enabledModes, let current = report.monitor.modeAvailability,
               current.status == "available", previous != current.enabledModeNumbers.sorted() { return false }
            let currentUsage = UInt64(report.monitor.usageHours) * 60 + UInt64(report.monitor.usageMinutes)
            if let usageMinutes, currentUsage < usageMinutes { return false }
            return true
        }

        mutating func invalidate() {
            graph = nil
            rows = nil
            information = nil
            configuration = nil
            enabledModes = nil
            usageMinutes = nil
        }
    }

    private func apply(_ result: MonitorRefreshResult) {
        if let registered = result.registeredMonitors {
            let allowed = Set(registered.map(\.id))
            saved = saved.filter { allowed.contains($0.key) }
        }
        if result.globalFailures.contains(where: { $0.kind == .noRegisteredMonitors }) { saved.removeAll() }
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
            let complete = !hasGlobalFailure && ((report.calibrationCountdown.status == "available" && value != nil)
                || (report.calibrationHistory.status == "available" && report.calibrationCountdown.status == "disabled"))
            let old = saved[identity.id]
            var previous = old ?? SavedMonitor(identity: identity)
            let failedReading = ["modeSelectionUnavailable", "invalidRecord", "databaseNotFound", "unavailable"]
                .contains(report.calibrationHistory.status)
            let keepPrevious = previous.permitsPreviousReading(for: report) && (hasGlobalFailure || failedReading)
            if complete {
                previous.graph = value
                previous.rows = ReminderMenuData(reports: [report]).rows
                previous.information = MonitorInformationValue(report: report)
                previous.configuration = report.calibrationConfiguration
                previous.enabledModes = report.monitor.modeAvailability?.enabledModeNumbers.sorted()
                previous.usageMinutes = UInt64(report.monitor.usageHours) * 60 + UInt64(report.monitor.usageMinutes)
                previous.date = .now
                updatedAt = previous.date
            } else if !keepPrevious {
                // A verified change must not reappear as an old reading on a later failure.
                previous.invalidate()
            }
            saved[identity.id] = previous
            let issue = sharedDBFailure ? nil : ReminderText.unavailable(report)
            next.append(MonitorDisplayState(identity: identity, report: report,
                graphValue: keepPrevious ? previous.graph ?? value : value, isStale: !complete,
                message: issue, detail: report.calibrationHistory.message ?? report.calibrationCountdown.message,
                lastSuccessAt: previous.date, previousRows: !complete && keepPrevious ? previous.rows : nil,
                previousInformation: !complete && keepPrevious ? previous.information : nil))
        }
        for failed in result.failures {
            let previous = saved[failed.identity.id]
                ?? saved.values.first { failed.identity.model == nil && failed.identity.serialNumber == nil
                    && failed.identity.registryID != nil && $0.identity.registryID == failed.identity.registryID }
            let identity = previous?.identity ?? failed.identity
            if saved[identity.id] == nil { saved[identity.id] = SavedMonitor(identity: identity) }
            next.append(MonitorDisplayState(identity: identity, graphValue: previous?.graph, isStale: true,
                message: failed.failure.displayMessage, detail: failed.failure.detail, lastSuccessAt: previous?.date,
                previousRows: previous?.rows, previousInformation: previous?.information))
        }
        let received = Set(next.map(\.id))
        for previous in saved.values where !received.contains(previous.identity.id) {
            next.append(MonitorDisplayState(identity: previous.identity, graphValue: previous.graph, isStale: true,
                message: !hasGlobalFailure || onlyMissing ? L10n.text("Monitor not found") : nil,
                lastSuccessAt: previous.date, previousRows: previous.rows, previousInformation: previous.information))
        }
        if onlyMissing && !next.isEmpty { globalMessages = [] }
        if next.isEmpty && globalMessages.isEmpty { globalMessages = [L10n.text("No matching monitors")] }
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
        cancelWakeRefresh()
        timerTask?.cancel()
        timerTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }
}
