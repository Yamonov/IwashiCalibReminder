import Foundation
import IOKit.hid

public struct MonitorReading: Codable, Sendable {
    public let model: String
    public let serialNumber: String
    public let vendorID: String
    public let productID: String
    public let locationID: String
    public let usageHours: UInt32
    public let usageMinutes: UInt8
    public let usageIdentifier: String
    public let rawPayload: String
    public let readAt: String
    public let elapsedMilliseconds: Double
    public var modeAvailability: MonitorModeAvailability?
}

public enum MonitorProbe {
    /// This prototype intentionally targets the CS2731 USB identity only.
    public static func read(format: String = "auto", verbose: Bool = false) throws -> [MonitorReading] {
        // Check before creating/opening the HID manager, including when called outside the CLI.
        let access = ColorNavigatorAccess.check()
        guard access.allowsMonitorAccess else {
            throw ProbeError(access.message + " Monitor access was skipped.")
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Int] = [
            kIOHIDVendorIDKey: 0x056D, kIOHIDProductIDKey: 0x4048,
            kIOHIDDeviceUsagePageKey: 0x80, kIOHIDDeviceUsageKey: 1
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        try checkIO(IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)), "Open HID manager")
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            throw ProbeError("CS2731 (USB 056D:4048) not found. Check the monitor's USB upstream connection.")
        }
        return try devices.sorted { location($0) < location($1) }.map {
            try Reader(device: $0, verbose: verbose).read(format: format)
        }
    }
}

private func location(_ device: IOHIDDevice) -> UInt32 {
    (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value ?? 0
}

private func checkIO(_ result: IOReturn, _ operation: String) throws {
    guard result == kIOReturnSuccess else {
        let detail = String(cString: mach_error_string(result))
        throw ProbeError(String(format: "%@: %@ (0x%08X)", operation, detail, UInt32(bitPattern: result)))
    }
}

private struct Reader {
    let device: IOHIDDevice
    let verbose: Bool

    func log(_ message: String) {
        if verbose { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    }

    func get(_ report: (id: UInt8, length: Int)) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: report.length)
        bytes[0] = report.id
        var length = report.length
        let result = bytes.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(report.id), $0.baseAddress!, &length)
        }
        try checkIO(result, "Get feature \(report.id)")
        guard length == report.length, bytes[0] == report.id else {
            throw ProbeError("Unexpected feature report \(report.id): length=\(length), ID=\(bytes[0])")
        }
        log("GET \(report.id) [\(length) bytes]: \(hex(Array(bytes.prefix(48))))\(length > 48 ? " ..." : "")")
        return bytes
    }

    /// Only descriptor selection and GET_VALUE requests are sent. No SET_VALUE API is exposed.
    func sendReadRequest(_ bytes: [UInt8], allowedID: UInt8) throws {
        guard bytes.first == allowedID, allowedID == 1 || allowedID == 3 else {
            throw ProbeError("Refusing a report other than descriptor selection or a read request")
        }
        log("REQUEST \(allowedID) [\(bytes.count) bytes]: \(hex(Array(bytes.prefix(16))))")
        let result = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(allowedID), $0.baseAddress!, bytes.count)
        }
        try checkIO(result, "Send read request \(allowedID)")
    }

    func secondaryDescriptor(_ report: (id: UInt8, length: Int)) throws -> [UInt8] {
        guard report.id == 1, report.length == 517 else { throw ProbeError("Unsupported descriptor transport") }
        var request = [UInt8](repeating: 0, count: report.length)
        request[0] = report.id
        try sendReadRequest(request, allowedID: report.id)
        var descriptor: [UInt8] = []
        var total: Int?
        repeat {
            let response = try get(report)
            let offset = Int(littleEndian(response[1..<3]))
            let size = Int(littleEndian(response[3..<5]))
            guard size > 0, size <= 16384, offset == descriptor.count,
                  total == nil || total == size else {
                throw ProbeError("Secondary descriptor changed or was interrupted by another client")
            }
            total = size
            let remaining = size - descriptor.count
            guard remaining > 0 else { throw ProbeError("Invalid secondary descriptor offset") }
            descriptor.append(contentsOf: response[5..<(5 + min(512, remaining))])
        } while descriptor.count < (total ?? 0)
        log("Secondary descriptor: \(descriptor.count) bytes")
        return descriptor
    }

    func read(format requested: String) throws -> MonitorReading {
        let started = ProcessInfo.processInfo.systemUptime
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
            throw ProbeError("HID report descriptor is unavailable")
        }
        let primary = try FeatureDescriptor(Array(data))
        let identityReport = try primary.report(0xFF300008)
        let counterReport = try primary.report(0xFF300006)
        let valueReport = try primary.report(0xFF300003)
        let statusReport = try primary.report(0xFF300007)
        guard identityReport == (8, 25), counterReport == (6, 3),
              valueReport == (3, 39), statusReport == (7, 8) else {
            throw ProbeError("Unsupported CS2731 feature report layout")
        }
        let identity = try get(identityReport)
        func identityString(_ range: Range<Int>) throws -> String {
            guard let text = String(bytes: identity[range], encoding: .ascii) else {
                throw ProbeError("Invalid monitor identity")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
        let serial = try identityString(1..<9)
        let model = try identityString(9..<25)
        guard model == "CS2731", !serial.isEmpty else { throw ProbeError("Unexpected monitor: \(model)") }
        log("Monitor: \(model), serial=\(serial), non-exclusive HID access")
        let secondary = try FeatureDescriptor(secondaryDescriptor(primary.report(0xFF300001)))
        let format = try UsageFormat.select(from: secondary, requested: requested)
        log("Selected usage: " + String(format: "0x%08X", format.usage))
        let payload = try readValue(usage: format.usage, count: format.byteCount,
                                    counterReport: counterReport, valueReport: valueReport, statusReport: statusReport)
        let usage = try UsageTime(payload: payload, format: format)
        let availability: MonitorModeAvailability
        do {
            guard let field = try secondary.field(0xFF0000F4), field.bits > 0,
                  field.bits % 8 == 0, field.bits / 8 <= 32 else {
                throw ProbeError("The monitor does not advertise a supported mode-enable report (0xFF0000F4)")
            }
            let flags = try readValue(usage: 0xFF0000F4, count: field.bits / 8,
                                      counterReport: counterReport, valueReport: valueReport, statusReport: statusReport)
            availability = try MonitorModeAvailability.decode(flags)
        } catch {
            availability = .unavailable(String(describing: error))
            log("Mode-enable state unavailable: \(error)")
        }
        return MonitorReading(
            model: model, serialNumber: serial, vendorID: "0x056D", productID: "0x4048",
            locationID: String(format: "0x%08X", location(device)), usageHours: usage.hours,
            usageMinutes: usage.minutes, usageIdentifier: String(format: "0x%08X", format.usage),
            rawPayload: hex(payload), readAt: ISO8601DateFormatter().string(from: Date()),
            elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
            modeAvailability: availability
        )
    }

    private func readValue(usage: UInt32, count: Int, counterReport: (id: UInt8, length: Int),
                           valueReport: (id: UInt8, length: Int), statusReport: (id: UInt8, length: Int)) throws -> [UInt8] {
        guard count > 0, count <= valueReport.length - 7 else { throw ProbeError("Unsupported read payload size") }
        let counterBytes = try get(counterReport)
        let counter = UInt16(littleEndian(counterBytes[1..<3]))
        let header = requestHeader(reportID: valueReport.id, usage: usage, counter: counter)
        let request = header + [UInt8](repeating: 0, count: valueReport.length - header.count)
        try sendReadRequest(request, allowedID: valueReport.id)
        let response = try get(valueReport)
        let payload = try checkedPayload(response: response, header: header, count: count)
        let statusHeader = requestHeader(reportID: statusReport.id, usage: usage, counter: counter)
        try checkStatus(get(statusReport), header: statusHeader)
        return payload
    }
}
