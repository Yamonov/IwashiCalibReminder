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
    public var registryID: String?
}

public enum MonitorProbe {
    public static func read(format: String = "auto", verbose: Bool = false) throws -> [MonitorReading] {
        try checkAccess()
        let registered = try CNDatabase.read(path: CNDatabase.defaultPath).registeredMonitors()
        let result = try readResult(registeredMonitors: registered, format: format, verbose: verbose)
        if let failure = result.globalFailures.first { throw failure }
        if let failure = result.failures.first { throw failure.failure }
        return result.readings
    }

    public static func readResult(registeredMonitors: [CNRegisteredMonitor], format: String = "auto",
                                  verbose: Bool = false, refreshID: String? = nil) throws -> MonitorProbeResult {
        try checkAccess()
        guard !registeredMonitors.isEmpty else {
            throw AcquisitionFailure(.noRegisteredMonitors, detail: "No monitors are registered in the ColorNavigator database", operation: "readRegistrations")
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Enumeration uses IOKit's existing registry. Devices are opened individually
        // only when an identity or a registered monitor's current values are needed.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x056D,
            kIOHIDDeviceUsagePageKey: 0x80, kIOHIDDeviceUsageKey: 1] as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [])
            .map { IOHIDMonitorDevice($0) }.sorted {
                ($0.connection.locationID, $0.connection.registryID ?? "")
                    < ($1.connection.locationID, $1.connection.registryID ?? "")
            }
        let store = MonitorDiscoveryCacheStore.standard
        var cache = store.load()
        var result = MonitorDiscovery.read(devices: devices, registered: registeredMonitors, cache: &cache,
            format: format, verbose: verbose, refreshID: refreshID)
        store.save(cache)
        if result.readings.isEmpty && result.failures.isEmpty && result.globalFailures.isEmpty {
            result.globalFailures.append(AcquisitionFailure(.notFound,
                detail: "No connected monitor matches the ColorNavigator database", operation: "discoverMonitors"))
        }
        if let refreshID {
            for failure in result.globalFailures {
                DiagnosticLog.shared.record(DiagnosticEvent("discovery.stopped", fields: [
                    "refreshID": refreshID, "code": failure.kind.rawValue, "detail": failure.detail], level: failure.diagnosticLevel))
            }
            let stats = result.discovery
            DiagnosticLog.shared.record(DiagnosticEvent("discovery.finished", fields: [
                "refreshID": refreshID, "enumeratedDevices": String(stats.enumeratedDevices),
                "registeredMonitors": String(stats.registeredMonitors), "matchedDevices": String(stats.matchedDevices),
                "cacheHits": String(stats.cacheHits), "identityReads": String(stats.identityReads),
                "capabilityReads": String(stats.capabilityReads), "featureGets": String(stats.featureGets),
                "featureSets": String(stats.featureSets)]))
        }
        return result
    }

    public static func checkAccess() throws {
        let access = ColorNavigatorAccess.check()
        guard access.allowsMonitorAccess else {
            throw AcquisitionFailure(access.state == "interfaceRunning" ? .cnInUse : .cnStateUnknown,
                                     detail: access.message, operation: "checkCN")
        }
    }
}

private func checkIO(_ result: IOReturn, _ operation: String) throws {
    guard result == kIOReturnSuccess else {
        throw AcquisitionFailure(.communication,
            detail: String(format: "%@: %@ (0x%08X)", operation, String(cString: mach_error_string(result)), UInt32(bitPattern: result)),
            operation: operation, ioReturn: result)
    }
}

private final class IOHIDMonitorDevice: MonitorDevice {
    private let device: IOHIDDevice
    let connection: MonitorConnection

    init(_ device: IOHIDDevice) {
        self.device = device
        func number(_ key: String) -> UInt32 {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.uint32Value ?? 0
        }
        var entryID: UInt64 = 0
        let status = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        connection = MonitorConnection(registryID: status == KERN_SUCCESS && entryID != 0 ? String(entryID) : nil,
            vendorID: number(kIOHIDVendorIDKey), productID: number(kIOHIDProductIDKey), version: number(kIOHIDVersionNumberKey),
            locationID: number(kIOHIDLocationIDKey),
            primaryDescriptor: IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data ?? Data())
    }

    func open() throws { try checkIO(IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)), "Open monitor") }
    func close() { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

    func getReport(_ report: MonitorReport) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: report.length)
        bytes[0] = report.id
        var length = bytes.count
        let result = bytes.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(report.id), $0.baseAddress!, &length)
        }
        try checkIO(result, "Get feature \(report.id)")
        guard (0...bytes.count).contains(length) else { throw ProbeError("Invalid feature response length") }
        return Array(bytes.prefix(length))
    }

    func sendReadRequest(_ bytes: [UInt8]) throws {
        guard let id = bytes.first else { throw ProbeError("Empty read request") }
        let result = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(id), $0.baseAddress!, bytes.count)
        }
        try checkIO(result, "Send read request \(id)")
    }
}
