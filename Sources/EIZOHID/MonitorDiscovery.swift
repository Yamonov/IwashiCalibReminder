import Foundation

enum MonitorDiscovery {
    /// Called once for an explicit update. No polling, retries, or persistent HID handles.
    static func read(devices: [any MonitorDevice], registered: [CNRegisteredMonitor],
                     cache: inout MonitorDiscoveryCache, format: String = "auto", verbose: Bool = false,
                     refreshID: String? = nil, accessCheck: () -> ColorNavigatorAccessCheck = ColorNavigatorAccess.check) -> MonitorProbeResult {
        var result = MonitorProbeResult()
        result.discovery.enumeratedDevices = devices.count
        result.discovery.registeredMonitors = registered.count
        cache.retain(devices.map(\.connection))
        let allowed = Set(registered)
        guard !allowed.isEmpty else { return result }
        var matched: Set<CNRegisteredMonitor> = []
        for device in devices {
            let cached = cache.entry(for: device.connection)
            if let cached {
                result.discovery.cacheHits += 1
                if !allowed.contains(cached.monitor) || matched.contains(cached.monitor) { continue }
            }
            var reader: MonitorReader?
            defer {
                if let reader {
                    result.discovery.identityReads += reader.statistics.identityReads
                    result.discovery.capabilityReads += reader.statistics.capabilityReads
                    result.discovery.featureGets += reader.statistics.featureGets
                    result.discovery.featureSets += reader.statistics.featureSets
                }
            }
            do {
                let layout = try MonitorControlLayout(device.connection.primaryDescriptor)
                let session = MonitorReader(device: device, layout: layout, verbose: verbose, refreshID: refreshID)
                reader = session
                session.monitor = cached?.monitor
                let access = accessCheck()
                guard access.allowsMonitorAccess else {
                    throw AcquisitionFailure(access.state == "interfaceRunning" ? .cnInUse : .cnStateUnknown,
                                             detail: access.message, operation: "checkCN")
                }
                // Opening only this device keeps a failure on one monitor local to it.
                try device.open()
                defer { device.close() }
                let monitor = try cached?.monitor ?? session.identify()
                cache.update(connection: device.connection, monitor: monitor, capabilities: cached?.capabilities)
                guard allowed.contains(monitor), matched.insert(monitor).inserted else { continue }
                result.discovery.matchedDevices += 1
                session.record("monitor.read_started", fields: ["cacheHit": String(cached?.capabilities != nil)])
                let capabilities = try cached?.capabilities ?? session.discoverCapabilities()
                cache.update(connection: device.connection, monitor: monitor, capabilities: capabilities)
                result.readings.append(try session.read(capabilities: capabilities, format: format))
            } catch {
                let failure = AcquisitionFailure.wrapping(error)
                if failure.kind == .cnInUse || failure.kind == .cnStateUnknown {
                    result.globalFailures.append(failure)
                    break
                }
                let identity = reader?.identity ?? device.connection.identity(cached?.monitor)
                result.failures.append(MonitorReadFailure(identity: identity, failure: failure))
                if let refreshID {
                    DiagnosticLog.shared.record(DiagnosticEvent("monitor.failed", fields: [
                        "refreshID": refreshID, "locationID": identity.locationID, "model": identity.model ?? "",
                        "serialNumber": identity.serialNumber ?? "", "code": failure.kind.rawValue, "detail": failure.detail,
                        "operation": failure.operation ?? "discovery", "ioReturn": failure.ioReturn.map(String.init) ?? ""],
                        level: failure.diagnosticLevel))
                }
            }
        }
        return result
    }
}
