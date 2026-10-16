import Darwin
import EIZOHID
import Foundation

struct ArgumentError: Error, CustomStringConvertible {
    let description: String
}

var snapshot = false
var refreshID: String?
var snapshotRegistrations: [CNRegisteredMonitor]?

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func printHistory(_ history: CNCalibrationHistory, countdown: CNCalibrationCountdown? = nil) {
    print("CN database: \(history.status) (\(history.sourcePath))")
    if let message = history.message { print("  \(message)") }
    if let scope = history.modeScope {
        print("  Mode scope: \(scope == "enabledModes" ? "enabled modes from monitor" : "all saved modes; includes disabled modes")")
    }
    if let policy = history.managementPolicy {
        print("  Management policy: \(policy.type ?? "not recorded")")
        let interval = policy.intervalHours.map { " (\($0) hours)" } ?? ""
        print("  Schedule: \(policy.scheduleType ?? "not recorded")\(interval)")
    }
    for mode in history.colorModes {
        let name = mode.targetName ?? mode.targetID ?? "unassigned"
        let modeName = mode.modeName.map { " (mode name: \($0))" } ?? ""
        print("  Mode \(mode.modeNumber): \(name)\(modeName) [\(mode.status)]")
        if let result = mode.lastCalibration {
            print("    Last calibration: \(result.executedDate ?? "not recorded")")
            if let hours = result.usageHours, let minutes = result.usageMinutes {
                print("    Usage at calibration: \(hours) hours \(minutes) minutes")
            } else { print("    Usage at calibration: not fully recorded") }
            if mode.historyScope == "sharedStandardModes" { print("    Source: shared standard-mode calibration") }
        }
        if let countdown {
            if let value = countdown.colorModes.first(where: { $0.modeNumber == mode.modeNumber }) {
                if let minutes = value.remainingMinutes {
                    print("    Calibration deadline: \(CalibrationCountdownText.remaining(minutes))")
                } else { print("    Calibration deadline: unavailable (\(value.message ?? value.status))") }
            } else { print("    Calibration deadline: unavailable (\(countdown.message ?? countdown.status))") }
        }
        if let message = mode.message { print("    \(message)") }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
        print("""
        eizo-usage [--json] [--verbose] [--all-modes] [--format auto|extended|legacy] [--database-path PATH]
        eizo-usage --database-only [--json] [--database-path PATH]
        eizo-usage --check-cn [--json]

        Read cumulative usage time from connected EIZO monitors registered in the CN database.
        Default: one reading per matched monitor, then exit. No monitor settings are changed.
        With usable CN history, print enabled modes' remaining usage time and the earliest deadline (all ties).
        Enable state is read from the monitor, separately from the targets assigned in the CN database.
        If ColorNavigator 7 is in application mode, exit with status 1 before monitor access. Agent-only mode is allowed.
        Devices are enumerated on each invocation; verified identities/capabilities are cached for the current connection and OS boot.
        The CN database is required. Unregistered devices receive no usage-time or mode-state queries.
        --json     Emit a JSON array of readings (diagnostics go to stderr).
        --verbose  Log HID requests/responses to stderr.
        --format   Select an advertised format; default is auto (extended first).
        --all-modes  Include disabled/unassigned modes for diagnostics instead of filtering enabled modes.
        --check-cn   Check CN application/Agent state only; no HID access or database read.
        --snapshot   App protocol: reports plus per-monitor/global failures; writes diagnostics to macOS unified logging.
        --refresh-id ID  Correlate an app update with its helper log entries (used with --snapshot).
        --database-path  CN LevelDB directory (default: /Library/Application Support/EIZO/ColorNavigator 7/db.0).
        --database-only  Read saved CN histories only, with no monitor access, even while CN is running.
                         Saved monitors may be disconnected. Reads original DB files directly in Swift.
                         No LevelDB/Snappy installation or temporary database copy is required.
                         Remaining time cannot be calculated without current monitor usage.
                         Lists all saved modes because enable state is not stored in the CN database.
        Exit status: 0 success, 1 read error, 2 invalid arguments.
        A 15-second process alarm bounds a stuck synchronous HID operation.
        """)
        exit(0)
    }
    var json = false
    var verbose = false
    var format = "auto"
    var databasePath = CNDatabase.defaultPath
    var databaseOnly = false
    var includeAllModes = false
    var checkCNOnly = false
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--json": json = true
        case "--verbose": verbose = true
        case "--database-only": databaseOnly = true
        case "--all-modes": includeAllModes = true
        case "--check-cn": checkCNOnly = true
        case "--snapshot": snapshot = true
        case "--refresh-id":
            index += 1
            guard index < arguments.count, UUID(uuidString: arguments[index]) != nil else {
                throw ArgumentError(description: "--refresh-id requires a UUID")
            }
            refreshID = arguments[index]
        case "--database-path":
            index += 1
            guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                throw ArgumentError(description: "--database-path requires a directory path")
            }
            databasePath = arguments[index]
        case "--format":
            index += 1
            guard index < arguments.count, ["auto", "extended", "legacy"].contains(arguments[index]) else {
                throw ArgumentError(description: "--format requires auto, extended, or legacy")
            }
            format = arguments[index]
        default: throw ArgumentError(description: "Unknown argument: \(arguments[index])")
        }
        index += 1
    }
    if checkCNOnly {
        let access = ColorNavigatorAccess.check()
        if json { try printJSON(access) }
        else {
            print("ColorNavigator state: \(access.state)")
            print(access.message)
        }
        exit(access.allowsMonitorAccess ? 0 : 1)
    }
    alarm(15)
    if databaseOnly {
        let database = CNDatabase.read(path: databasePath)
        alarm(0)
        if json { try printJSON(database) }
        else {
            print("Saved CN monitor records (no HID communication; monitors may be disconnected)")
            print("Remaining usage time: unavailable (current monitor usage was not read)")
            print("Mode filtering: unavailable (enable state must be read from the monitor; showing all saved modes)")
            print("Database: \(database.status) (\(database.sourcePath))")
            if let message = database.message { print(message) }
            for monitor in database.storedMonitors {
                print("\n\(monitor.model)  S/N \(monitor.serialNumber)")
                printHistory(monitor.calibrationHistory)
            }
        }
        exit(database.status == "unavailable" ? 1 : 0)
    }
    try MonitorProbe.checkAccess()
    if snapshot { refreshID = refreshID ?? UUID().uuidString }
    if let refreshID {
        DiagnosticLog.shared.record(DiagnosticEvent("database.read_started", fields: ["refreshID": refreshID], level: .debug))
    }
    let database = CNDatabase.read(path: databasePath)
    if let refreshID {
        DiagnosticLog.shared.record(DiagnosticEvent("database.read_finished", fields: [
            "refreshID": refreshID, "status": database.status, "detail": database.message ?? ""],
            level: database.status == "available" ? .info : .error))
    }
    let registered = try database.registeredMonitors()
    snapshotRegistrations = registered
    let probe = try MonitorProbe.readResult(registeredMonitors: registered, format: format, verbose: verbose, refreshID: refreshID)
    let reports = probe.readings.map {
        MonitorUsageReport(monitor: $0, calibrationHistory: database.history(model: $0.model, serial: $0.serialNumber),
                           includeAllModes: includeAllModes)
    }
    if snapshot {
        alarm(0)
        try printJSON(MonitorRefreshResult(reports: reports, failures: probe.failures,
            globalFailures: probe.globalFailures, discovery: probe.discovery, registeredMonitors: registered))
        exit(0)
    }
    if let failure = probe.globalFailures.first { throw failure }
    if let failure = probe.failures.first { throw failure.failure }
    alarm(0)
    if json {
        try printJSON(reports)
    } else {
        for report in reports {
            let reading = report.monitor
            print("\(reading.model)  S/N \(reading.serialNumber)")
            print("Usage time: \(reading.usageHours) hours \(reading.usageMinutes) minutes")
            print("USB HID \(reading.vendorID):\(reading.productID)  usage=\(reading.usageIdentifier)")
            print("Raw value: \(reading.rawPayload)")
            print("Read at: \(reading.readAt)  (\(String(format: "%.1f", reading.elapsedMilliseconds)) ms)")
            printHistory(report.calibrationHistory, countdown: report.calibrationCountdown)
            print(CalibrationCountdownText.earliest(report.calibrationCountdown))
        }
    }
} catch {
    if snapshot, !(error is ArgumentError) {
        alarm(0)
        let failure = AcquisitionFailure.wrapping(error)
        DiagnosticLog.shared.record(DiagnosticEvent("helper.acquisition_failed", fields: [
            "refreshID": refreshID ?? "", "code": failure.kind.rawValue, "detail": failure.detail,
            "operation": failure.operation ?? "probe", "ioReturn": failure.ioReturn.map(String.init) ?? ""],
            level: failure.diagnosticLevel))
        if let data = try? JSONEncoder().encode(MonitorRefreshResult(globalFailures: [failure], registeredMonitors: snapshotRegistrations)) {
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        }
    }
    FileHandle.standardError.write(Data("eizo-usage: \(error)\n".utf8))
    exit(error is ArgumentError ? 2 : 1)
}
