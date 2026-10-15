import Foundation

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// Only the byte-aligned, single-usage Feature fields used by this protocol.
/// Unknown fields still contribute to their report's total length.
struct FeatureDescriptor {
    struct Field {
        let usage: UInt32
        let reportID: UInt8
        let bits: Int
    }
    var fields: [Field] = []
    var reportBits: [UInt8: Int] = [:]

    init(_ bytes: [UInt8]) throws {
        struct Globals {
            var page: UInt32 = 0
            var id: UInt8 = 0
            var size: Int = 0
            var count: Int = 0
        }
        var state = Globals()
        var stack: [Globals] = []
        var usages: [UInt32] = []
        var hasRange = false
        var cursor = 0
        while cursor < bytes.count {
            let prefix = bytes[cursor]
            cursor += 1
            guard prefix != 0xFE else { throw ProbeError("Unsupported HID long item") }
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard cursor + size <= bytes.count else { throw ProbeError("Truncated HID descriptor") }
            let value = littleEndian(bytes[cursor..<(cursor + size)])
            cursor += size
            let type = (prefix >> 2) & 3
            let tag = prefix >> 4
            if type == 1 {
                switch tag {
                case 0: state.page = value
                case 7: state.size = Int(value)
                case 8:
                    guard value > 0, value <= 255 else { throw ProbeError("Invalid HID report ID") }
                    state.id = UInt8(value)
                case 9: state.count = Int(value)
                case 10: stack.append(state)
                case 11:
                    guard let restored = stack.popLast() else { throw ProbeError("Invalid HID global pop") }
                    state = restored
                default: break
                }
            } else if type == 2 {
                if tag == 0 {
                    usages.append(size == 4 ? value : (state.page << 16) | value)
                } else if tag == 1 || tag == 2 || tag == 10 {
                    hasRange = true
                }
            } else if type == 0 {
                if tag == 11 {
                    guard state.size > 0, state.size <= 4096,
                          state.count > 0, state.count <= 65536 else {
                        throw ProbeError("Invalid HID feature dimensions")
                    }
                    let bits = state.size * state.count
                    let total = reportBits[state.id, default: 0] + bits
                    guard total <= 524288 else { throw ProbeError("HID report is too large") }
                    reportBits[state.id] = total
                    // Ignore Constant and Array fields; do not guess usage ranges.
                    if value & 3 == 2, usages.count == 1, !hasRange, bits % 8 == 0 {
                        fields.append(Field(usage: usages[0], reportID: state.id, bits: bits))
                    }
                }
                usages.removeAll(keepingCapacity: true)
                hasRange = false
            }
        }
        guard stack.isEmpty else { throw ProbeError("Unbalanced HID global stack") }
    }

    func field(_ usage: UInt32) throws -> Field? {
        let matching = fields.filter { $0.usage == usage }
        guard matching.count <= 1 else { throw ProbeError("Ambiguous HID usage") }
        return matching.first
    }

    func report(_ usage: UInt32) throws -> (id: UInt8, length: Int) {
        guard let field = try field(usage), field.reportID != 0,
              reportBits[field.reportID] == field.bits else {
            throw ProbeError(String(format: "Unsupported HID report layout for 0x%08X", usage))
        }
        return (field.reportID, 1 + field.bits / 8)
    }
}

enum UsageFormat: String {
    case legacy, extended
    var usage: UInt32 { self == .extended ? 0xFF000047 : 0xFF000037 }
    var byteCount: Int { self == .extended ? 5 : 3 }

    static func select(from descriptor: FeatureDescriptor, requested: String) throws -> UsageFormat {
        let candidates: [UsageFormat] = requested == "auto" ? [.extended, .legacy] :
            UsageFormat(rawValue: requested).map { [$0] } ?? []
        for format in candidates {
            if let field = try descriptor.field(format.usage) {
                guard field.bits == format.byteCount * 8 else {
                    throw ProbeError("Unexpected usage-time payload size: \(field.bits) bits")
                }
                return format
            }
        }
        throw ProbeError("Requested usage-time format is not advertised by the monitor")
    }
}

struct UsageTime {
    let hours: UInt32
    let minutes: UInt8

    init(payload: [UInt8], format: UsageFormat) throws {
        guard payload.count == format.byteCount else { throw ProbeError("Truncated usage-time value") }
        let minutes = payload[payload.count - 1]
        guard minutes < 60 else { throw ProbeError("Invalid usage-time minutes: \(minutes)") }
        hours = littleEndian(payload.dropLast())
        self.minutes = minutes
    }
}

func requestHeader(reportID: UInt8, usage: UInt32, counter: UInt16) -> [UInt8] {
    [reportID, UInt8(truncatingIfNeeded: usage >> 16), UInt8(truncatingIfNeeded: usage >> 24),
     UInt8(truncatingIfNeeded: usage), UInt8(truncatingIfNeeded: usage >> 8),
     UInt8(truncatingIfNeeded: counter), UInt8(truncatingIfNeeded: counter >> 8)]
}

func checkedPayload(response: [UInt8], header: [UInt8], count: Int) throws -> [UInt8] {
    guard response.count >= header.count + count else { throw ProbeError("Truncated monitor response") }
    guard Array(response.prefix(header.count)) == header else {
        throw ProbeError("Response usage/counter mismatch; another client may be communicating")
    }
    return Array(response[header.count..<(header.count + count)])
}

func checkStatus(_ response: [UInt8], header: [UInt8]) throws {
    let status = try checkedPayload(response: response, header: header, count: 1)[0]
    guard status == 0 else { throw ProbeError("Monitor rejected request, status=\(status)") }
}
