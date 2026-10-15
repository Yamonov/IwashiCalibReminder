import CryptoKit
import Foundation

/// Immutable in-memory file bytes, followed by a second read to reject concurrent changes.
/// This is not a cooperative/atomic LevelDB snapshot; no DB engine or write API is called.
struct LevelDBFileSnapshot {
    private struct Stamp: Equatable {
        let size: Int
        let fileID: UInt64
        let modified: Date
    }
    private struct Captured {
        let data: Data
        let stamp: Stamp
        let digest: SHA256.Digest
    }
    static let maximumBytes = 256 * 1024 * 1024
    let directory: URL
    let names: Set<String>
    private var captured: [String: Captured] = [:]
    private var byteCount = 0

    init(directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LevelDBReadError.invalid("database path is not a regular directory")
        }
        self.directory = directory
        names = try Self.inventory(directory)
        guard names.contains("CURRENT") else { throw LevelDBReadError.invalid("CURRENT is missing") }
    }

    static func number(_ name: String, suffix: String) -> UInt64? {
        guard name.hasSuffix(suffix) else { return nil }
        let digits = name.dropLast(suffix.count)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(digits)
    }

    static func filename(_ number: UInt64, suffix: String) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits + suffix
    }

    mutating func load(_ name: String) throws -> Data {
        if let file = captured[name] { return file.data }
        guard names.contains(name), !name.contains("/"), !name.contains("\0") else {
            throw LevelDBReadError.invalid("referenced file is missing: \(name)")
        }
        let url = directory.appendingPathComponent(name)
        let stamp = try Self.stamp(url)
        guard stamp.size <= Self.maximumBytes - byteCount else {
            throw LevelDBReadError.invalid("database exceeds the 256 MiB read limit")
        }
        let bytes = try Self.read(url, expectedSize: stamp.size)
        guard try Self.stamp(url) == stamp else { throw LevelDBReadError.invalid("file changed during read: \(name)") }
        captured[name] = Captured(data: bytes, stamp: stamp, digest: SHA256.hash(data: bytes))
        byteCount += bytes.count
        return bytes
    }

    func validateUnchanged() throws {
        guard try Self.inventory(directory) == names else { throw LevelDBReadError.invalid("database file list changed during read") }
        // Recheck CURRENT/MANIFEST last, since they select all other file contents.
        let ordered = captured.keys.sorted {
            func priority(_ name: String) -> Int { name == "CURRENT" ? 2 : name.hasPrefix("MANIFEST-") ? 1 : 0 }
            return (priority($0), $0) < (priority($1), $1)
        }
        for name in ordered {
            guard let file = captured[name] else { continue }
            let url = directory.appendingPathComponent(name)
            guard try Self.stamp(url) == file.stamp,
                  SHA256.hash(data: try Self.read(url, expectedSize: file.stamp.size)) == file.digest,
                  try Self.stamp(url) == file.stamp else {
                throw LevelDBReadError.invalid("database changed during read: \(name)")
            }
        }
        guard try Self.inventory(directory) == names else { throw LevelDBReadError.invalid("database file list changed during validation") }
    }

    private static func inventory(_ directory: URL) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0 == "CURRENT" || $0.hasPrefix("MANIFEST-") ||
                [".ldb", ".sst", ".log"].contains(where: $0.hasSuffix)
        }
        guard names.count <= 4096 else { throw LevelDBReadError.invalid("too many database files") }
        return Set(names)
    }

    private static func stamp(_ url: URL) throws -> Stamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              size.int64Value <= maximumBytes, let id = attributes[.systemFileNumber] as? NSNumber,
              let date = attributes[.modificationDate] as? Date else {
            throw LevelDBReadError.invalid("invalid file type or size: \(url.lastPathComponent)")
        }
        return Stamp(size: size.intValue, fileID: id.uint64Value, modified: date)
    }

    private static func read(_ url: URL, expectedSize: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(65536, expectedSize - result.count + 1)), !chunk.isEmpty {
            guard chunk.count <= expectedSize - result.count else {
                throw LevelDBReadError.invalid("file grew during read: \(url.lastPathComponent)")
            }
            result.append(chunk)
        }
        guard result.count == expectedSize else { throw LevelDBReadError.invalid("short file read: \(url.lastPathComponent)") }
        return result
    }
}

enum LevelDBDirectReader {
    /// Returns the logical key/value view. Deleted keys stay absent even if older tables contain values.
    static func read(directory: URL) throws -> [Data: Data] {
        var files = try LevelDBFileSnapshot(directory: directory)
        let current = try files.load("CURRENT")
        guard current.count <= 4096, let text = String(data: current, encoding: .utf8), text.hasSuffix("\n") else {
            throw LevelDBReadError.invalid("invalid CURRENT")
        }
        let manifestName = String(text.dropLast())
        guard manifestName.hasPrefix("MANIFEST-"),
              let number = UInt64(manifestName.dropFirst("MANIFEST-".count)),
              manifestName == "MANIFEST-" + LevelDBFileSnapshot.filename(number, suffix: "") else {
            throw LevelDBReadError.invalid("invalid MANIFEST filename in CURRENT")
        }
        let manifest = try LevelDBManifest(files.load(manifestName))
        var latest = LevelDBLatestValues()
        for table in manifest.tables {
            let ldb = LevelDBFileSnapshot.filename(table.number, suffix: ".ldb")
            let sst = LevelDBFileSnapshot.filename(table.number, suffix: ".sst")
            // LevelDB's documented legacy .sst extension is used only if .ldb is absent.
            let name = files.names.contains(ldb) ? ldb : sst
            for record in try LevelDBTable.read(files.load(name), metadata: table) { try latest.apply(record) }
        }
        let logs = files.names.compactMap { name -> (UInt64, String)? in
            guard let number = LevelDBFileSnapshot.number(name, suffix: ".log"),
                  number >= manifest.logNumber || number == manifest.previousLogNumber else { return nil }
            return (number, name)
        }.sorted { $0.0 < $1.0 }
        guard manifest.logNumber == 0 || logs.contains(where: { $0.0 >= manifest.logNumber }) else {
            throw LevelDBReadError.invalid("current update log is missing")
        }
        var seenLogs: Set<UInt64> = []
        for (number, name) in logs {
            guard name == LevelDBFileSnapshot.filename(number, suffix: ".log"), seenLogs.insert(number).inserted else {
                throw LevelDBReadError.invalid("invalid or duplicate log filename")
            }
            for batch in try LevelDBLog.records(files.load(name)) {
                for record in try LevelDBLog.writeBatch(batch) { try latest.apply(record) }
            }
        }
        // LastSequence in MANIFEST is a checkpoint, not an upper bound on subsequent WAL writes.
        try files.validateUnchanged()
        return latest.values
    }
}
