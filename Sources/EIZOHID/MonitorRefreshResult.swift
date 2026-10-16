import Foundation

public struct MonitorIdentity: Codable, Hashable, Sendable {
    public let model: String?
    public let serialNumber: String?
    public let locationID: String
    public let registryID: String?

    public init(model: String?, serialNumber: String?, locationID: String, registryID: String? = nil) {
        self.model = model
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.registryID = registryID
    }

    public var id: String {
        if let model, let serialNumber, !model.isEmpty, !serialNumber.isEmpty {
            return model + ":" + serialNumber
        }
        return registryID.map { "HID:" + $0 } ?? "USB:" + locationID
    }
}

extension MonitorReading {
    public var identity: MonitorIdentity {
        MonitorIdentity(model: model, serialNumber: serialNumber, locationID: locationID, registryID: registryID)
    }
}

public struct AcquisitionFailure: Error, Codable, Sendable, LocalizedError {
    public enum Kind: String, Codable, Sendable {
        case cnInUse, cnStateUnknown, notFound, noRegisteredMonitors, communication, unsupported, invalidResponse
        case databaseUnavailable, helper
    }

    public let kind: Kind
    public let detail: String
    public let operation: String?
    public let ioReturn: Int32?

    public init(_ kind: Kind, detail: String, operation: String? = nil, ioReturn: Int32? = nil) {
        self.kind = kind
        self.detail = detail
        self.operation = operation
        self.ioReturn = ioReturn
    }

    public var errorDescription: String? { detail }

    public var diagnosticLevel: DiagnosticEvent.Level {
        switch kind {
        case .cnInUse, .notFound, .noRegisteredMonitors: .notice
        default: .error
        }
    }

    public static func wrapping(_ error: any Error) -> AcquisitionFailure {
        if let failure = error as? AcquisitionFailure { return failure }
        if let failure = error as? ProbeError { return failure.failure }
        return AcquisitionFailure(.invalidResponse, detail: String(describing: error))
    }
}

public struct MonitorReadFailure: Codable, Sendable {
    public let identity: MonitorIdentity
    public let failure: AcquisitionFailure

    public init(identity: MonitorIdentity, failure: AcquisitionFailure) {
        self.identity = identity
        self.failure = failure
    }
}

public struct MonitorProbeResult: Sendable {
    public var readings: [MonitorReading] = []
    public var failures: [MonitorReadFailure] = []
    public var globalFailures: [AcquisitionFailure] = []
    public var discovery = MonitorDiscoveryStatistics()
}

public struct MonitorDiscoveryStatistics: Codable, Sendable {
    public var enumeratedDevices = 0
    public var registeredMonitors = 0
    public var matchedDevices = 0
    public var cacheHits = 0
    public var identityReads = 0
    public var capabilityReads = 0
    public var featureGets = 0
    public var featureSets = 0
}

/// The app uses this envelope; the original CLI JSON array remains available.
public struct MonitorRefreshResult: Codable, Sendable {
    public let schemaVersion: Int
    public let reports: [MonitorUsageReport]
    public let failures: [MonitorReadFailure]
    public let globalFailures: [AcquisitionFailure]
    public let discovery: MonitorDiscoveryStatistics?
    public let registeredMonitors: [CNRegisteredMonitor]?

    public init(reports: [MonitorUsageReport] = [], failures: [MonitorReadFailure] = [],
                globalFailures: [AcquisitionFailure] = [], discovery: MonitorDiscoveryStatistics? = nil,
                registeredMonitors: [CNRegisteredMonitor]? = nil) {
        schemaVersion = 1
        self.reports = reports
        self.failures = failures
        self.globalFailures = globalFailures
        self.discovery = discovery
        self.registeredMonitors = registeredMonitors
    }
}
