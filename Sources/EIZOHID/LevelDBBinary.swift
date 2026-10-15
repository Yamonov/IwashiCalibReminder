import Foundation

enum LevelDBReadError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let reason): return "LevelDB direct read: \(reason)" }
    }
}

/// Bounds-checked byte decoding; no aligned loads from external file buffers.
struct LevelDBBytes {
    let bytes: [UInt8]
    var position = 0
    var remaining: Int { bytes.count - position }

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ data: Data) { bytes = Array(data) }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw LevelDBReadError.invalid("truncated field") }
        defer { position += count }
        return Array(bytes[position..<(position + count)])
    }

    mutating func fixed(_ count: Int) throws -> UInt64 {
        guard (1...8).contains(count), count <= remaining else { throw LevelDBReadError.invalid("truncated integer") }
        var value: UInt64 = 0
        for shift in 0..<count {
            value |= UInt64(bytes[position]) << (shift * 8)
            position += 1
        }
        return value
    }

    mutating func varint(bits: Int = 64) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: bits, by: 7) {
            let byte = try fixed(1)
            let payload = byte & 0x7F
            guard payload < (UInt64(1) << min(7, bits - shift)) else {
                throw LevelDBReadError.invalid("varint overflow")
            }
            value |= payload << shift
            if byte & 0x80 == 0 { return value }
        }
        throw LevelDBReadError.invalid("unterminated varint")
    }

    mutating func field() throws -> [UInt8] {
        let length = try varint(bits: 32)
        guard length <= UInt64(remaining) else { throw LevelDBReadError.invalid("truncated length-prefixed field") }
        return try take(Int(length))
    }
}

enum LevelDBCRC32C {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0x82F63B78) }
        return value
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc = UInt32.max
        for byte in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)] }
        return ~crc
    }

    static func masked<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        let crc = checksum(bytes)
        return ((crc >> 15) | (crc << 17)) &+ 0xA282EAD8
    }
}

struct LevelDBRecord {
    static let maximumSequence: UInt64 = (1 << 56) - 1
    let key: Data
    let sequence: UInt64
    let value: Data? // nil is a deletion, retained until all versions have been compared.

    static func internalKey(_ key: [UInt8], value: [UInt8]) throws -> LevelDBRecord {
        guard key.count >= 8 else { throw LevelDBReadError.invalid("short internal key") }
        var tail = LevelDBBytes(Array(key.suffix(8)))
        let tag = try tail.fixed(8)
        let kind = tag & 0xFF
        guard kind <= 1, kind != 0 || value.isEmpty else {
            throw LevelDBReadError.invalid("invalid value/deletion record")
        }
        return LevelDBRecord(key: Data(key.dropLast(8)), sequence: tag >> 8, value: kind == 1 ? Data(value) : nil)
    }

    static func precedes(_ left: [UInt8], _ right: [UInt8]) throws -> Bool {
        guard left.count >= 8, right.count >= 8 else { throw LevelDBReadError.invalid("short internal key") }
        let a = left.dropLast(8), b = right.dropLast(8)
        if a != b { return a.lexicographicallyPrecedes(b) }
        var at = LevelDBBytes(Array(left.suffix(8))), bt = LevelDBBytes(Array(right.suffix(8)))
        return try at.fixed(8) > bt.fixed(8)
    }
}

struct LevelDBLatestValues {
    private var latest: [Data: LevelDBRecord] = [:]

    mutating func apply(_ record: LevelDBRecord) throws {
        guard record.sequence <= LevelDBRecord.maximumSequence else { throw LevelDBReadError.invalid("sequence overflow") }
        if let previous = latest[record.key] {
            if previous.sequence > record.sequence { return }
            if previous.sequence == record.sequence {
                guard previous.value == record.value else { throw LevelDBReadError.invalid("conflicting records at the same sequence") }
                return
            }
        }
        latest[record.key] = record
    }

    var values: [Data: Data] { latest.compactMapValues(\.value) }
}
