import Foundation

enum LevelDBTable {
    struct Handle {
        let offset: UInt64
        let size: UInt64
        init(_ input: inout LevelDBBytes) throws {
            offset = try input.varint()
            size = try input.varint()
        }
    }
    struct Entry {
        let key: [UInt8]
        let value: [UInt8]
    }

    static func read(_ data: Data, metadata: LevelDBManifest.Table) throws -> [LevelDBRecord] {
        let bytes = Array(data)
        guard data.count >= 48, UInt64(data.count) == metadata.size else {
            throw LevelDBReadError.invalid("table size does not match MANIFEST")
        }
        let footerStart = bytes.count - 48
        var footer = LevelDBBytes(Array(bytes[footerStart...]))
        let metaindex = try Handle(&footer)
        let index = try Handle(&footer)
        guard footer.position <= 40, try footer.take(40 - footer.position).allSatisfy({ $0 == 0 }),
              try footer.fixed(8) == 0xDB4775248B80FB57 else {
            throw LevelDBReadError.invalid("invalid table footer")
        }
        try checkBounds(metaindex, limit: footerStart)
        let indexBytes = try block(bytes, handle: index, limit: footerStart)
        let indexEntries = try entries(indexBytes)
        var result: [LevelDBRecord] = []
        var lastKey: [UInt8]?
        var lastIndexKey: [UInt8]?
        var firstKey: [UInt8]?
        var previousBlockEnd: UInt64 = 0
        for entry in indexEntries {
            _ = try LevelDBRecord.internalKey(entry.key, value: [])
            if let previous = lastIndexKey, try !LevelDBRecord.precedes(previous, entry.key) {
                throw LevelDBReadError.invalid("unordered table index")
            }
            var handleBytes = LevelDBBytes(entry.value)
            let handle = try Handle(&handleBytes)
            guard handleBytes.remaining == 0, handle.offset >= previousBlockEnd else {
                throw LevelDBReadError.invalid("invalid or overlapping data block handle")
            }
            let content = try block(bytes, handle: handle, limit: Int(index.offset))
            let values = try entries(content)
            guard !values.isEmpty else { throw LevelDBReadError.invalid("empty indexed data block") }
            if let previousIndex = lastIndexKey, let first = values.first,
               try !LevelDBRecord.precedes(previousIndex, first.key) {
                throw LevelDBReadError.invalid("invalid index key range")
            }
            for item in values {
                if let previous = lastKey, try !LevelDBRecord.precedes(previous, item.key) {
                    throw LevelDBReadError.invalid("unordered table keys")
                }
                result.append(try LevelDBRecord.internalKey(item.key, value: item.value))
                if firstKey == nil { firstKey = item.key }
                lastKey = item.key
            }
            if let lastKey, lastKey != entry.key, try !LevelDBRecord.precedes(lastKey, entry.key) {
                throw LevelDBReadError.invalid("data block exceeds its index key")
            }
            lastIndexKey = entry.key
            previousBlockEnd = handle.offset + handle.size + 5 // Bounds already checked.
        }
        guard firstKey == metadata.smallest, lastKey == metadata.largest else {
            throw LevelDBReadError.invalid("table key bounds do not match MANIFEST")
        }
        return result
    }

    private static func checkBounds(_ handle: Handle, limit: Int) throws {
        guard limit >= 5, handle.offset <= UInt64(limit - 5),
              handle.size <= UInt64(limit - 5) - handle.offset else {
            throw LevelDBReadError.invalid("table block is outside the file")
        }
    }

    private static func block(_ bytes: [UInt8], handle: Handle, limit: Int) throws -> [UInt8] {
        guard limit <= bytes.count else { throw LevelDBReadError.invalid("invalid table block boundary") }
        try checkBounds(handle, limit: limit)
        let offset = Int(handle.offset), size = Int(handle.size)
        let compression = bytes[offset + size]
        var trailer = LevelDBBytes(Array(bytes[(offset + size + 1)..<(offset + size + 5)]))
        let crc = try trailer.fixed(4)
        guard UInt64(LevelDBCRC32C.masked(bytes[offset..<(offset + size + 1)])) == crc else {
            throw LevelDBReadError.invalid("table block CRC32C mismatch")
        }
        guard compression == 0 else {
            throw LevelDBReadError.invalid("unsupported table compression type \(compression); this reader supports uncompressed blocks")
        }
        return Array(bytes[offset..<(offset + size)])
    }

    /// Reconstruct prefix-compressed keys and validate every restart offset.
    static func entries(_ bytes: [UInt8]) throws -> [Entry] {
        guard bytes.count >= 8 else { throw LevelDBReadError.invalid("short table block") }
        var tail = LevelDBBytes(Array(bytes.suffix(4)))
        let count = Int(try tail.fixed(4))
        guard count > 0, count <= (bytes.count - 4) / 4 else {
            throw LevelDBReadError.invalid("invalid restart count")
        }
        let end = bytes.count - (count + 1) * 4
        var restartInput = LevelDBBytes(Array(bytes[end..<(bytes.count - 4)]))
        var offsets: [Int] = []
        for _ in 0..<count {
            let offset = Int(try restartInput.fixed(4))
            guard (end == 0 && offset == 0) || offset < end,
                  offsets.last.map({ offset > $0 }) ?? (offset == 0) else {
                throw LevelDBReadError.invalid("invalid restart offset")
            }
            offsets.append(offset)
        }
        if end == 0 { return [] }
        let restarts = Set(offsets)
        var seen: Set<Int> = []
        var input = LevelDBBytes(Array(bytes[..<end]))
        var previous: [UInt8] = []
        var result: [Entry] = []
        while input.remaining > 0 {
            let position = input.position
            let shared = Int(try input.varint(bits: 32))
            let unshared = Int(try input.varint(bits: 32))
            let valueLength = Int(try input.varint(bits: 32))
            guard shared <= previous.count, shared + unshared <= 1024 * 1024 else {
                throw LevelDBReadError.invalid("invalid shared-key length")
            }
            if restarts.contains(position) {
                guard shared == 0 else { throw LevelDBReadError.invalid("restart entry has a shared prefix") }
                seen.insert(position)
            }
            let key = Array(previous.prefix(shared)) + (try input.take(unshared))
            let value = try input.take(valueLength)
            result.append(Entry(key: key, value: value))
            previous = key
        }
        guard seen == restarts else { throw LevelDBReadError.invalid("restart offset is not an entry boundary") }
        return result
    }
}
