import Foundation

enum LevelDBLog {
    static let blockSize = 32768
    static let maximumRecordSize = 64 * 1024 * 1024

    /// Used for both MANIFEST and WAL. Incomplete tails fail rather than returning older data.
    static func records(_ data: Data) throws -> [[UInt8]] {
        var input = LevelDBBytes(data)
        var result: [[UInt8]] = []
        var fragmented: [UInt8]?
        while input.remaining > 0 {
            let inBlock = blockSize - input.position % blockSize
            if inBlock < 7 {
                guard input.remaining >= inBlock, try input.take(inBlock).allSatisfy({ $0 == 0 }) else {
                    throw LevelDBReadError.invalid("invalid log block trailer")
                }
                continue
            }
            guard input.remaining >= 7 else { throw LevelDBReadError.invalid("incomplete log header") }
            let checksum = try input.fixed(4)
            let length = Int(try input.fixed(2))
            let type = UInt8(try input.fixed(1))
            if type == 0, length == 0, checksum == 0 {
                let padding = min(inBlock - 7, input.remaining)
                guard fragmented == nil, try input.take(padding).allSatisfy({ $0 == 0 }) else {
                    throw LevelDBReadError.invalid("invalid zero-filled log block")
                }
                continue
            }
            guard (1...4).contains(type), length <= inBlock - 7 else {
                throw LevelDBReadError.invalid("invalid log record header")
            }
            let payload = try input.take(length)
            guard UInt64(LevelDBCRC32C.masked([type] + payload)) == checksum else {
                throw LevelDBReadError.invalid("log CRC32C mismatch")
            }
            switch type {
            case 1:
                guard fragmented == nil else { throw LevelDBReadError.invalid("unfinished fragmented log record") }
                result.append(payload)
            case 2:
                guard fragmented == nil else { throw LevelDBReadError.invalid("duplicate first log fragment") }
                fragmented = payload
            case 3, 4:
                guard let count = fragmented?.count, count <= maximumRecordSize - payload.count else {
                    throw LevelDBReadError.invalid("missing first fragment or oversized log record")
                }
                fragmented?.append(contentsOf: payload)
                if type == 4, let completed = fragmented { result.append(completed); fragmented = nil }
            default: break // Type has been checked above.
            }
        }
        guard fragmented == nil else { throw LevelDBReadError.invalid("incomplete fragmented log record") }
        return result
    }

    static func writeBatch(_ bytes: [UInt8]) throws -> [LevelDBRecord] {
        var input = LevelDBBytes(bytes)
        let sequence = try input.fixed(8)
        let count = try input.fixed(4)
        guard sequence <= LevelDBRecord.maximumSequence, count <= UInt64(input.remaining / 2),
              count == 0 || count - 1 <= LevelDBRecord.maximumSequence - sequence else {
            throw LevelDBReadError.invalid("invalid write batch count/sequence")
        }
        var records: [LevelDBRecord] = []
        for index in 0..<count {
            let type = try input.fixed(1)
            guard type <= 1 else { throw LevelDBReadError.invalid("unknown write batch operation") }
            let key = try input.field()
            let value = type == 1 ? Data(try input.field()) : nil
            records.append(LevelDBRecord(key: Data(key), sequence: sequence + index, value: value))
        }
        guard input.remaining == 0 else { throw LevelDBReadError.invalid("write batch has extra data") }
        return records
    }
}

struct LevelDBManifest {
    struct Table {
        let level: UInt64
        let number: UInt64
        let size: UInt64
        let smallest: [UInt8]
        let largest: [UInt8]
    }
    let tables: [Table]
    let logNumber: UInt64
    let previousLogNumber: UInt64

    init(_ data: Data) throws {
        var comparator: String?
        var logNumber: UInt64?
        var previousLogNumber: UInt64 = 0
        var nextFile: UInt64?
        var lastSequence: UInt64?
        var active: [UInt64: Table] = [:]
        for record in try LevelDBLog.records(data) {
            var input = LevelDBBytes(record)
            var removed: [(UInt64, UInt64)] = []
            var added: [Table] = []
            while input.remaining > 0 {
                let tag = try input.varint(bits: 32)
                switch tag {
                case 1:
                    guard let name = String(bytes: try input.field(), encoding: .utf8), name == "leveldb.BytewiseComparator" else {
                        throw LevelDBReadError.invalid("unsupported comparator")
                    }
                    comparator = name
                case 2: logNumber = try input.varint()
                case 3: nextFile = try input.varint()
                case 4:
                    let sequence = try input.varint()
                    guard sequence <= LevelDBRecord.maximumSequence else { throw LevelDBReadError.invalid("manifest sequence overflow") }
                    lastSequence = sequence
                case 5:
                    guard try input.varint(bits: 32) < 7 else { throw LevelDBReadError.invalid("invalid compaction level") }
                    let key = try input.field()
                    _ = try LevelDBRecord.internalKey(key, value: [])
                case 6:
                    let level = try input.varint(bits: 32), number = try input.varint()
                    guard level < 7, number > 0 else { throw LevelDBReadError.invalid("invalid removed table") }
                    removed.append((level, number))
                case 7:
                    let level = try input.varint(bits: 32), number = try input.varint(), size = try input.varint()
                    let smallest = try input.field(), largest = try input.field()
                    _ = try LevelDBRecord.internalKey(smallest, value: [])
                    _ = try LevelDBRecord.internalKey(largest, value: [])
                    let ordered = try LevelDBRecord.precedes(smallest, largest)
                    guard level < 7, number > 0, size >= 48,
                          smallest == largest || ordered else {
                        throw LevelDBReadError.invalid("invalid table metadata")
                    }
                    added.append(Table(level: level, number: number, size: size, smallest: smallest, largest: largest))
                case 9: previousLogNumber = try input.varint()
                default: throw LevelDBReadError.invalid("unknown MANIFEST tag \(tag)")
                }
            }
            // VersionEdit applies removals before additions, including a table moved between levels.
            for (level, number) in removed where active[number]?.level == level { active[number] = nil }
            for table in added {
                guard active[table.number] == nil else { throw LevelDBReadError.invalid("duplicate active table") }
                active[table.number] = table
            }
        }
        guard comparator != nil, let logNumber, nextFile != nil, lastSequence != nil else {
            throw LevelDBReadError.invalid("MANIFEST is missing required metadata")
        }
        tables = active.values.sorted { $0.number < $1.number }
        self.logNumber = logNumber
        self.previousLogNumber = previousLogNumber
    }
}
