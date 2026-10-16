import Foundation
import os

/// Small diagnostic events; timestamps and storage are owned by unified logging.
/// Monitor payloads, calibration measurements, and complete DB records are excluded.
public struct DiagnosticEvent: Sendable {
    public enum Level: Equatable, Sendable {
        case debug, info, notice, error

        fileprivate var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice: .default
            case .error: .error
            }
        }
    }

    public let event: String
    public let fields: [String: String]
    public let level: Level

    public init(_ event: String, fields: [String: String] = [:], level: Level = .info) {
        self.event = event
        self.fields = fields.mapValues { String($0.prefix(4_096)) }
        self.level = level
    }
}

public final class DiagnosticLog: Sendable {
    public static let shared = DiagnosticLog()
    private static let logger = Logger(subsystem: "com.iwashiya.IwashiCalibReminder", category: "Diagnostics")
    private let sink: (@Sendable (DiagnosticEvent) -> Void)?

    private init() { sink = nil }

    /// Tests capture events without depending on system log retention or filesystem I/O.
    init(sink: @escaping @Sendable (DiagnosticEvent) -> Void) { self.sink = sink }

    public func record(_ event: DiagnosticEvent) {
        if let sink {
            sink(event)
            return
        }
        var fields = event.fields
        let serial = fields.removeValue(forKey: "serialNumber") ?? ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metadata = (try? encoder.encode(fields)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        Self.logger.log(level: event.level.osLogType,
            "\(event.event, privacy: .public) \(metadata, privacy: .public) serial=\(serial, privacy: .private(mask: .hash))")
    }
}
