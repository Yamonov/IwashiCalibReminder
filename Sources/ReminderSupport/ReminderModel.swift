import EIZOHID
import Foundation
import Observation

@Observable @MainActor
public final class ReminderModel {
    public enum Phase: Equatable { case idle, waiting, suspended, loading, ready, blocked, failed }
    public enum RefreshReason: String, Sendable { case startup, scheduled, manual, wake, login, retry }
    public enum PowerEvent: String, Sendable { case systemWillSleep, displaysDidSleep, systemDidWake, displaysDidWake }
    public private(set) var phase: Phase = .idle
    public private(set) var reports: [MonitorUsageReport] = []
    public private(set) var monitors: [MonitorDisplayState] = []
    public private(set) var globalMessages: [String] = []
    public private(set) var message: String?
    public private(set) var attemptedAt: Date?
    public private(set) var updatedAt: Date?
    public var isSuspended: Bool { phase == .suspended }
    public var canRefresh: Bool { !stopped && !isSuspended && refreshTask == nil }

    private struct Attempt: Sendable {
        var reason: RefreshReason
        var recovery: RefreshReason?
        var retryIndex = 0
    }

    private struct ReadState {
        let id: UUID
        let phase: Phase
        let messages: [String]
        let detail: String?
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activeRead: ReadState?
    @ObservationIgnored private var delayTask: Task<Void, Never>?
    @ObservationIgnored private var delayGeneration: UUID?
    @ObservationIgnored private var scheduledAttempt: Attempt?
    @ObservationIgnored private var pendingAttempt: Attempt?
    @ObservationIgnored private var loginDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var systemSleeping = false
    @ObservationIgnored private var displaysSleeping = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var initialWaitFinished = false
    @ObservationIgnored private let timing: RefreshTiming
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private let wait: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let reader: @Sendable (String) async throws -> MonitorRefreshResult
    @ObservationIgnored private let diagnostics: DiagnosticLog?
    @ObservationIgnored private var saved: [String: SavedMonitor] = [:]
    @ObservationIgnored private let accessCheck: @MainActor () -> ColorNavigatorAccessCheck
    @ObservationIgnored private let displayState: @MainActor () -> DisplayPowerState
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored public var didRead: (@MainActor ([MonitorUsageReport]) -> Void)?
    @ObservationIgnored public var didFinishInitialWait: (@MainActor () -> Void)?
    var wakeRefreshPending: Bool { pendingAttempt?.reason == .wake }

    deinit {
        // A weak capture does not end a task. Request cancellation when the
        // owner disappears so cooperative operations can release their captures.
        refreshTask?.cancel()
        delayTask?.cancel()
    }

    public init(refreshInterval: Duration = .seconds(3_600),
                reader: (@Sendable () async throws -> [MonitorUsageReport])? = nil,
                snapshotReader: @escaping @Sendable (String) async throws -> MonitorRefreshResult = {
                    try await HelperClient.bundled().readSnapshot(refreshID: $0)
                }, diagnostics: DiagnosticLog? = nil,
                accessCheck: @escaping @MainActor () -> ColorNavigatorAccessCheck = { ColorNavigatorAccess.check() },
                displayState: @escaping @MainActor () -> DisplayPowerState = { DisplayPowerState.current() },
                timing: RefreshTiming = RefreshTiming(),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.refreshInterval = refreshInterval
        if let reader { self.reader = { _ in MonitorRefreshResult(reports: try await reader()) } }
        else { self.reader = snapshotReader }
        self.diagnostics = diagnostics
        self.accessCheck = accessCheck
        self.displayState = displayState
        self.timing = timing
        self.now = now
        self.wait = wait
    }

    public var summary: ReminderSummary { ReminderSummary(reports: reports) }

    public var menuTitle: String {
        switch phase {
        case .idle, .loading: return L10n.text("Reading…")
        case .waiting: return L10n.text("Waiting to read…")
        case .suspended: return L10n.text("Reading paused")
        case .blocked: return L10n.text("CN in use")
        case .failed: return L10n.text("Unavailable")
        case .ready: return summary.remainingMinutes.map(ReminderText.menuTitle) ?? L10n.text("Remaining —")
        }
    }

    public var symbol: String {
        if phase == .blocked || phase == .suspended { return "pause.circle" }
        if phase == .failed { return "exclamationmark.triangle" }
        if let minutes = summary.remainingMinutes, minutes <= 0 { return "display.trianglebadge.exclamationmark" }
        return "display"
    }

    public func start(launchReason: ApplicationLaunchReason = .regular) {
        guard !started else { return }
        stopped = false
        started = true
        if launchReason == .loginItem {
            loginDeadline = now().advanced(by: timing.login)
            if displayState() == .asleep { suspend() }
            else { schedule(Attempt(reason: .login, recovery: .login), after: timing.login) }
        } else { refresh(reason: .startup) }
    }

    public func refresh(reason: RefreshReason = .manual) {
        guard !Task.isCancelled, !stopped, refreshTask == nil else { return }
        if reason == .scheduled, scheduledAttempt != nil || pendingAttempt != nil { return }
        if reason == .manual { loginDeadline = nil }
        cancelSchedule()
        perform(Attempt(reason: reason, recovery: [.wake, .login].contains(reason) ? reason : nil))
    }

    public func handlePowerEvent(_ event: PowerEvent) {
        guard !stopped else { return }
        diagnostics?.record(DiagnosticEvent("power.changed", fields: ["event": event.rawValue], level: .notice))
        switch event {
        case .systemWillSleep:
            systemSleeping = true
            suspend()
        case .displaysDidSleep:
            displaysSleeping = true
            suspend()
        case .systemDidWake:
            systemSleeping = false
            displaysSleeping = displayState() == .asleep
            refreshAfterWake()
        case .displaysDidWake:
            displaysSleeping = false
            refreshAfterWake()
        }
    }

    /// Coalesce wake notifications, without shortening an outstanding login delay.
    public func refreshAfterWake() {
        guard !stopped else { return }
        if systemSleeping || displaysSleeping {
            suspend()
            return
        }
        freezePreviousReading()
        let reason: RefreshReason = loginDeadline == nil ? .wake : .login
        schedule(Attempt(reason: reason, recovery: reason), after: timing.wake)
    }

    private func schedule(_ attempt: Attempt, after delay: Duration) {
        cancelSchedule()
        let generation = UUID()
        delayGeneration = generation
        scheduledAttempt = attempt
        let current = now()
        let deadline = max(current.advanced(by: delay), loginDeadline ?? current)
        let duration = current.duration(to: deadline)
        if attempt.reason != .scheduled { showWaiting(attempt) }
        diagnostics?.record(DiagnosticEvent("refresh.scheduled", fields: [
            "reason": attempt.reason.rawValue, "attempt": String(attempt.retryIndex),
            "delaySeconds": String(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)],
            level: attempt.reason == .scheduled ? .debug : .notice))
        delayTask = Task.detached(priority: .utility) { [weak self, wait] in
            do { try await wait(duration) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.delayFinished(generation, attempt: attempt)
        }
    }

    private func delayFinished(_ generation: UUID, attempt: Attempt) {
        guard !stopped, delayGeneration == generation else { return }
        delayTask = nil
        delayGeneration = nil
        scheduledAttempt = nil
        if refreshTask != nil { pendingAttempt = attempt }
        else { perform(attempt) }
    }

    private func cancelSchedule() {
        delayTask?.cancel()
        delayTask = nil
        delayGeneration = nil
        scheduledAttempt = nil
        pendingAttempt = nil
    }

    private func showWaiting(_ attempt: Attempt) {
        phase = .waiting
        let text: String
        if attempt.reason == .retry { text = L10n.text("Waiting to retry monitor information… (%ld/3)", attempt.retryIndex) }
        else if attempt.reason == .login { text = L10n.text("Waiting to read monitor information after login…") }
        else { text = L10n.text("Waiting to read monitor information after wake…") }
        globalMessages = [text]
    }

    private func perform(_ attempt: Attempt) {
        guard !Task.isCancelled, !stopped, refreshTask == nil else { return }
        let power = displayState()
        if systemSleeping || displaysSleeping { suspend(); return }
        if power == .asleep {
            // The workspace wake event can precede WindowServer's power-state
            // change. Recheck the OS state within the same finite recovery budget;
            // no helper, DB read or HID operation is started while it is asleep.
            if let recovery = attempt.recovery, attempt.retryIndex < timing.retries.count {
                diagnostics?.record(DiagnosticEvent("refresh.power_not_ready",
                    fields: ["reason": attempt.reason.rawValue, "attempt": String(attempt.retryIndex)], level: .notice))
                schedule(Attempt(reason: .retry, recovery: recovery, retryIndex: attempt.retryIndex + 1),
                    after: timing.retries[attempt.retryIndex])
            } else { suspend() }
            return
        }
        loginDeadline = nil
        let generation = UUID()
        activeRead = ReadState(id: generation, phase: phase, messages: globalMessages, detail: message)
        let identifier = generation.uuidString
        let began = ProcessInfo.processInfo.systemUptime
        attemptedAt = .now
        message = nil
        diagnostics?.record(DiagnosticEvent("refresh.started", fields: [
            "refreshID": identifier, "reason": attempt.reason.rawValue, "attempt": String(attempt.retryIndex),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""], level: .notice))
        if let failure = power.denial {
            finishRefresh(MonitorRefreshResult(globalFailures: [failure]), generation: generation, started: began, attempt: attempt)
            return
        }
        if !initialWaitFinished {
            initialWaitFinished = true
            didFinishInitialWait?()
        }
        if let failure = accessCheck().denial {
            finishRefresh(MonitorRefreshResult(globalFailures: [failure]), generation: generation, started: began, attempt: attempt)
            return
        }
        phase = .loading
        globalMessages = [L10n.text("Refreshing monitor information…")]
        refreshTask = Task.detached(priority: .utility) { [weak self, reader] in
            let result: MonitorRefreshResult
            do {
                result = try await reader(identifier)
            } catch is CancellationError {
                await self?.finishCancelledRead(generation)
                return
            }
            catch {
                let kind: AcquisitionFailure.Kind = (error as? HelperError).map {
                    if case .timedOut = $0 { return .communication }
                    return .helper
                } ?? .helper
                result = MonitorRefreshResult(globalFailures: [AcquisitionFailure(kind, detail: error.localizedDescription, operation: "runHelper")])
            }
            guard !Task.isCancelled else {
                await self?.finishCancelledRead(generation)
                return
            }
            await self?.finishRefresh(result, generation: generation, started: began, attempt: attempt)
        }
    }

    private func finishRefresh(_ result: MonitorRefreshResult, generation: UUID, started began: TimeInterval, attempt: Attempt) {
        guard !stopped, activeRead?.id == generation else { return }
        refreshTask = nil
        activeRead = nil
        if result.globalFailures.contains(where: { $0.kind == .displayAsleep }) { suspend(); return }
        apply(result)
        logCompletion(generation.uuidString, started: began, failures: result.globalFailures)
        if let scheduledAttempt { showWaiting(scheduledAttempt); return }
        if let pendingAttempt {
            self.pendingAttempt = nil
            perform(pendingAttempt)
            return
        }
        if let recovery = attempt.recovery, result.needsRecoveryRetry, attempt.retryIndex < timing.retries.count {
            schedule(Attempt(reason: .retry, recovery: recovery, retryIndex: attempt.retryIndex + 1),
                     after: timing.retries[attempt.retryIndex])
            return
        }
        if !reports.isEmpty { didRead?(reports) }
        if started { schedule(Attempt(reason: .scheduled), after: refreshInterval) }
    }

    private func finishCancelledRead(_ generation: UUID) {
        guard !stopped, let previous = activeRead, previous.id == generation else { return }
        refreshTask = nil
        activeRead = nil
        phase = previous.phase == .waiting || previous.phase == .loading ? .idle : previous.phase
        globalMessages = phase == .idle ? [] : previous.messages
        message = previous.detail
        if let scheduledAttempt { showWaiting(scheduledAttempt); return }
        if let pendingAttempt {
            self.pendingAttempt = nil
            // Start the pending work in its own task, not in the cancelled
            // task's context where perform() must refuse to start new I/O.
            schedule(pendingAttempt, after: .zero)
        } else if started {
            schedule(Attempt(reason: .scheduled), after: refreshInterval)
        }
    }

    private func freezePreviousReading() {
        reports = []
        monitors = monitors.map { state in
            let previous = saved[state.id]
            return MonitorDisplayState(identity: state.identity, graphValue: previous?.graph ?? state.graphValue,
                isStale: true, lastSuccessAt: previous?.date ?? state.lastSuccessAt,
                previousRows: previous?.rows ?? state.previousRows,
                previousInformation: previous?.information ?? state.previousInformation)
        }
    }

    private func suspend() {
        cancelSchedule()
        activeRead = nil
        refreshTask?.cancel()
        refreshTask = nil
        freezePreviousReading()
        phase = .suspended
        globalMessages = [L10n.text("Reading is paused while the displays are asleep")]
        message = nil
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
        stopped = true
        started = false
        cancelSchedule()
        loginDeadline = nil
        activeRead = nil
        refreshTask?.cancel()
        refreshTask = nil
    }
}
