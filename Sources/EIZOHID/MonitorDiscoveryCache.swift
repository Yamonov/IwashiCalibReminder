import CryptoKit
import Darwin
import Foundation

struct MonitorConnection: Sendable {
    let registryID: String?
    let vendorID: UInt32
    let productID: UInt32
    let version: UInt32
    let locationID: UInt32
    let primaryDescriptor: Data

    var location: String { String(format: "0x%08X", locationID) }

    var fingerprint: MonitorConnectionFingerprint? {
        guard let registryID else { return nil }
        return MonitorConnectionFingerprint(registryID: registryID, vendorID: vendorID, productID: productID,
            version: version, locationID: locationID,
            descriptorHash: SHA256.hash(data: primaryDescriptor).map { String(format: "%02x", $0) }.joined())
    }

    func identity(_ monitor: CNRegisteredMonitor?) -> MonitorIdentity {
        MonitorIdentity(model: monitor?.model, serialNumber: monitor?.serialNumber,
                        locationID: location, registryID: registryID)
    }
}

struct MonitorConnectionFingerprint: Codable, Equatable, Sendable {
    let registryID: String
    let vendorID: UInt32
    let productID: UInt32
    let version: UInt32
    let locationID: UInt32
    let descriptorHash: String
}

struct MonitorDiscoveryEntry: Codable, Equatable, Sendable {
    let fingerprint: MonitorConnectionFingerprint
    let monitor: CNRegisteredMonitor
    var capabilities: MonitorCapabilities?
}

struct MonitorDiscoveryCache: Sendable {
    private(set) var entries: [String: MonitorDiscoveryEntry] = [:]

    init(entries: [MonitorDiscoveryEntry] = []) {
        for entry in entries { self.entries[entry.fingerprint.registryID] = entry }
    }

    func entry(for connection: MonitorConnection) -> MonitorDiscoveryEntry? {
        guard let fingerprint = connection.fingerprint, let entry = entries[fingerprint.registryID],
              entry.fingerprint == fingerprint else { return nil }
        return entry
    }

    mutating func retain(_ connections: [MonitorConnection]) {
        let current = Dictionary(connections.compactMap { connection in
            connection.fingerprint.map { ($0.registryID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        entries = entries.filter { current[$0.key] == $0.value.fingerprint }
    }

    mutating func update(connection: MonitorConnection, monitor: CNRegisteredMonitor,
                         capabilities: MonitorCapabilities?) {
        guard let fingerprint = connection.fingerprint else { return }
        entries[fingerprint.registryID] = MonitorDiscoveryEntry(fingerprint: fingerprint, monitor: monitor, capabilities: capabilities)
    }
}

/// Only identity and static communication capabilities survive a helper process.
/// Usage, enabled modes, calibration history, and computed remaining time are never cached here.
struct MonitorDiscoveryCacheStore {
    private struct Document: Codable {
        let version: Int
        let bootSessionID: String
        let entries: [MonitorDiscoveryEntry]
    }
    private static let schemaVersion = 1
    private static let maximumBytes = 262_144
    private static let maximumEntries = 64
    let url: URL
    let bootSessionID: String?

    static var standard: MonitorDiscoveryCacheStore {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return MonitorDiscoveryCacheStore(url: directory.appendingPathComponent("com.iwashiya.IwashiCalibReminder/discovery.json"),
                                          bootSessionID: currentBootSessionID())
    }

    func load() -> MonitorDiscoveryCache {
        guard let bootSessionID else { return MonitorDiscoveryCache() }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes else { return MonitorDiscoveryCache() }
            guard let data = try boundedData() else { return MonitorDiscoveryCache() }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == Self.schemaVersion, document.bootSessionID == bootSessionID,
                  document.entries.count <= Self.maximumEntries,
                  Set(document.entries.map { $0.fingerprint.registryID }).count == document.entries.count,
                  document.entries.allSatisfy(Self.isValid) else { return MonitorDiscoveryCache() }
            return MonitorDiscoveryCache(entries: document.entries)
        } catch { return MonitorDiscoveryCache() }
    }

    func save(_ cache: MonitorDiscoveryCache) {
        guard let bootSessionID else { return }
        do {
            let entries = Array(cache.entries.values.sorted { $0.fingerprint.registryID < $1.fingerprint.registryID }
                .prefix(Self.maximumEntries))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(version: Self.schemaVersion, bootSessionID: bootSessionID, entries: entries))
            guard data.count <= Self.maximumBytes else { return }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes,
               (try? boundedData()) == data { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            DiagnosticLog.shared.record(DiagnosticEvent("discovery.cache_write_failed",
                fields: ["detail": String(describing: error)], level: .notice))
        }
    }

    private static func isValid(_ entry: MonitorDiscoveryEntry) -> Bool {
        entry.monitor.isValid && entry.monitor.model.utf8.count <= 16 && entry.monitor.serialNumber.utf8.count <= 8
            && UInt64(entry.fingerprint.registryID) != nil && entry.fingerprint.vendorID == 0x056D
            && entry.fingerprint.descriptorHash.utf8.count == 64
            && entry.fingerprint.descriptorHash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && (entry.capabilities?.isValid ?? true)
    }

    private func boundedData() throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: Self.maximumBytes + 1), data.count <= Self.maximumBytes else { return nil }
        return data
    }

    private static func currentBootSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, (2...128).contains(size) else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return UUID(uuidString: String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))?.uuidString
    }
}
