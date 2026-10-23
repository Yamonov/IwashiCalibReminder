import Foundation

struct MonitorReport: Equatable, Sendable {
    let id: UInt8
    let length: Int
}

/// The EIZO monitor-control transport verified by this reader. HID usages select
/// report IDs; the proprietary packet layouts are checked before any requests.
struct MonitorControlLayout: Sendable {
    let descriptor: MonitorReport
    let identity: MonitorReport
    let counter: MonitorReport
    let value: MonitorReport
    let status: MonitorReport

    init(_ data: Data) throws {
        let primary = try FeatureDescriptor(Array(data))
        func report(_ usage: UInt32) throws -> MonitorReport {
            let result = try primary.report(usage)
            return MonitorReport(id: result.id, length: result.length)
        }
        descriptor = try report(0xFF300001)
        identity = try report(0xFF300008)
        counter = try report(0xFF300006)
        value = try report(0xFF300003)
        status = try report(0xFF300007)
        guard descriptor.length == 517, identity.length == 25, counter.length == 3,
              value.length == 39, status.length == 8,
              Set([descriptor.id, identity.id, counter.id, value.id, status.id]).count == 5 else {
            throw ProbeError("Unsupported EIZO monitor-control report layout", kind: .unsupported)
        }
    }
}

struct MonitorCapabilities: Codable, Equatable, Sendable {
    let extendedBits: Int?
    let legacyBits: Int?
    let modeBits: Int?

    init(descriptor: [UInt8]) throws {
        let fields = try FeatureDescriptor(descriptor)
        extendedBits = try fields.field(0xFF000047)?.bits
        legacyBits = try fields.field(0xFF000037)?.bits
        modeBits = try fields.field(0xFF0000F4)?.bits
    }

    var isValid: Bool {
        [extendedBits, legacyBits, modeBits].compactMap { $0 }.allSatisfy { (8...524_288).contains($0) && $0 % 8 == 0 }
    }

    func usageFormat(requested: String) throws -> UsageFormat {
        try UsageFormat.select(requested: requested) { format in
            format == .extended ? extendedBits : legacyBits
        }
    }

    func modeByteCount() throws -> Int {
        guard let modeBits, modeBits > 0, modeBits % 8 == 0, modeBits / 8 <= 32 else {
            throw ProbeError("The monitor does not advertise a supported mode-enable report (0xFF0000F4)", kind: .unsupported)
        }
        return modeBits / 8
    }
}

protocol MonitorDevice {
    var connection: MonitorConnection { get }
    func open() throws
    func close()
    func getReport(_ report: MonitorReport) throws -> [UInt8]
    func sendReadRequest(_ bytes: [UInt8]) throws
}

final class MonitorReader {
    let device: any MonitorDevice
    let layout: MonitorControlLayout
    let verbose: Bool
    let refreshID: String?
    private let accessCheck: () -> ColorNavigatorAccessCheck
    private let powerCheck: () -> AcquisitionFailure?
    private let started = ProcessInfo.processInfo.systemUptime
    var monitor: CNRegisteredMonitor?
    var statistics = MonitorDiscoveryStatistics()

    init(device: any MonitorDevice, layout: MonitorControlLayout, verbose: Bool, refreshID: String?,
         accessCheck: @escaping () -> ColorNavigatorAccessCheck, powerCheck: @escaping () -> AcquisitionFailure? = { nil }) {
        self.device = device
        self.layout = layout
        self.verbose = verbose
        self.refreshID = refreshID
        self.accessCheck = accessCheck
        self.powerCheck = powerCheck
    }

    var identity: MonitorIdentity { device.connection.identity(monitor) }

    func record(_ event: String, fields: [String: String] = [:], level: DiagnosticEvent.Level = .debug) {
        guard let refreshID else { return }
        var values = fields
        values["refreshID"] = refreshID
        values["locationID"] = identity.locationID
        values["model"] = monitor?.model
        values["serialNumber"] = monitor?.serialNumber
        DiagnosticLog.shared.record(DiagnosticEvent(event, fields: values, level: level))
    }

    func identify() throws -> CNRegisteredMonitor {
        statistics.identityReads += 1
        let bytes = try get(layout.identity)
        func string(_ range: Range<Int>) throws -> String {
            guard let value = String(bytes: bytes[range], encoding: .ascii) else { throw ProbeError("Invalid monitor identity") }
            return value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
        let result = try CNRegisteredMonitor(model: string(9..<25), serialNumber: string(1..<9))
        guard result.isValid else { throw ProbeError("Invalid monitor identity") }
        monitor = result
        return result
    }

    func discoverCapabilities() throws -> MonitorCapabilities {
        statistics.capabilityReads += 1
        record("monitor.read_step", fields: ["operation": "secondaryDescriptor"])
        var request = [UInt8](repeating: 0, count: layout.descriptor.length)
        request[0] = layout.descriptor.id
        try send(request, report: layout.descriptor)
        var descriptor: [UInt8] = []
        var total: Int?
        repeat {
            let response = try get(layout.descriptor)
            let offset = Int(littleEndian(response[1..<3]))
            let size = Int(littleEndian(response[3..<5]))
            guard size > 0, size <= 16_384, offset == descriptor.count, total == nil || total == size else {
                throw ProbeError("Secondary descriptor changed or was interrupted by another client")
            }
            total = size
            let remaining = size - descriptor.count
            guard remaining > 0 else { throw ProbeError("Invalid secondary descriptor offset") }
            descriptor.append(contentsOf: response[5..<(5 + min(512, remaining))])
        } while descriptor.count < (total ?? 0)
        return try MonitorCapabilities(descriptor: descriptor)
    }

    func read(capabilities: MonitorCapabilities, format requested: String) throws -> MonitorReading {
        guard let monitor else { throw ProbeError("Monitor identity was not established") }
        let format = try capabilities.usageFormat(requested: requested)
        record("monitor.read_step", fields: ["operation": "usageTime"])
        let payload = try readValue(usage: format.usage, count: format.byteCount)
        let usage = try UsageTime(payload: payload, format: format)
        let availability: MonitorModeAvailability
        record("monitor.read_step", fields: ["operation": "enabledModes"])
        do {
            let count = try capabilities.modeByteCount()
            availability = try MonitorModeAvailability.decode(readValue(usage: 0xFF0000F4, count: count))
        } catch {
            let failure = AcquisitionFailure.wrapping(error)
            if [.cnInUse, .cnStateUnknown, .displayAsleep, .displayStateUnknown].contains(failure.kind) { throw failure }
            availability = .unavailable(String(describing: error), failure: failure)
            record("monitor.mode_state_failed", fields: ["operation": "enabledModes", "detail": String(describing: error)], level: .error)
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        record("monitor.read_finished", fields: ["elapsedMilliseconds": String(elapsed), "modeState": availability.status], level: .info)
        return MonitorReading(model: monitor.model, serialNumber: monitor.serialNumber,
            vendorID: String(format: "0x%04X", device.connection.vendorID), productID: String(format: "0x%04X", device.connection.productID),
            locationID: device.connection.location, usageHours: usage.hours, usageMinutes: usage.minutes,
            usageIdentifier: String(format: "0x%08X", format.usage), rawPayload: hex(payload),
            readAt: Date.now.ISO8601Format(), elapsedMilliseconds: elapsed,
            modeAvailability: availability, registryID: device.connection.registryID)
    }

    private func get(_ report: MonitorReport) throws -> [UInt8] {
        if let denial = powerCheck() { throw denial }
        statistics.featureGets += 1
        let bytes = try device.getReport(report)
        guard bytes.count == report.length, bytes.first == report.id else {
            throw ProbeError("Unexpected feature report \(report.id): length=\(bytes.count)")
        }
        if verbose { FileHandle.standardError.write(Data("GET \(report.id) [\(bytes.count) bytes]: \(hex(Array(bytes.prefix(48))))\n".utf8)) }
        return bytes
    }

    private func send(_ bytes: [UInt8], report: MonitorReport) throws {
        guard report == layout.descriptor || report == layout.value,
              bytes.first == report.id, bytes.count == report.length else {
            throw ProbeError("Refusing a report other than descriptor selection or a read request")
        }
        if let denial = powerCheck() { throw denial }
        if let denial = accessCheck().denial { throw denial }
        statistics.featureSets += 1
        if verbose { FileHandle.standardError.write(Data("REQUEST \(report.id) [\(bytes.count) bytes]\n".utf8)) }
        try device.sendReadRequest(bytes)
    }

    private func readValue(usage: UInt32, count: Int) throws -> [UInt8] {
        guard count > 0, count <= layout.value.length - 7 else { throw ProbeError("Unsupported read payload size") }
        let counterBytes = try get(layout.counter)
        let counter = UInt16(littleEndian(counterBytes[1..<3]))
        let header = requestHeader(reportID: layout.value.id, usage: usage, counter: counter)
        try send(header + [UInt8](repeating: 0, count: layout.value.length - header.count), report: layout.value)
        let response = try get(layout.value)
        let payload = try checkedPayload(response: response, header: header, count: count)
        try checkStatus(get(layout.status), header: requestHeader(reportID: layout.status.id, usage: usage, counter: counter))
        return payload
    }
}
