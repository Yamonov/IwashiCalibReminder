import CryptoKit
import Foundation

public struct CNCalibrationHistory: Codable, Sendable {
    public let sourcePath: String
    public let status: String
    public var message: String?
    public var databaseVersion: String?
    public var modeScope: String?
    public var managementPolicy: CNManagementPolicy?
    public var monitorDetails: CNJSONValue?
    public var commonSettings: CNCommonSettings?
    public var colorModes: [CNColorModeHistory] = []
}

public struct CNManagementPolicy: Codable, Equatable, Sendable {
    public let type: String?
    public let scheduleType: String?
    public let intervalHours: Int?
    public var calendarSchedule: CNCalibrationSchedule? = nil
}

/// Small comparison value captured before filtering by the monitor's enabled modes.
/// It deliberately excludes measurements, LUTs and other raw database records.
public struct CNCalibrationConfiguration: Codable, Equatable, Sendable {
    private let policy: CNManagementPolicy?
    private let modes: [Mode]

    private struct Mode: Codable, Equatable, Sendable {
        let number: Int
        let targetID: String?
        let targetName: String?
        let targetSettingsDigest: String?
        let name: String?
        let type: String?
        let status: String
        let calibrationID: String?
        let calibratedAt: String?
        let usageHours: UInt32?
        let usageMinutes: UInt8?
    }

    init?(history: CNCalibrationHistory) {
        guard history.status == "available" else { return nil }
        policy = history.managementPolicy
        modes = history.colorModes.map {
            Mode(number: $0.modeNumber, targetID: $0.targetID, targetName: $0.targetName,
                 targetSettingsDigest: $0.targetConfigurationDigest ?? Self.digest($0.targetDetails),
                 name: $0.modeName, type: $0.modeType, status: $0.status,
                 calibrationID: $0.lastCalibration?.resultID, calibratedAt: $0.lastCalibration?.executedDate,
                 usageHours: $0.lastCalibration?.usageHours, usageMinutes: $0.lastCalibration?.usageMinutes)
        }.sorted { $0.number < $1.number }
    }

    private static func digest(_ value: CNJSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CNColorModeHistory: Codable, Sendable {
    public let modeNumber: Int
    public let targetID: String?
    public var targetName: String?
    public var modeName: String?
    public var modeType: String?
    public var historyScope: String?
    public var status: String
    public var message: String?
    public var lastCalibration: CNCalibrationRecord?
    public var targetDetails: CNJSONValue? {
        didSet { targetConfigurationDigest = nil }
    }
    /// Fingerprint of the full source record, including fields omitted from compact UI data.
    public var targetConfigurationDigest: String? = nil
}

public struct CNCalibrationRecord: Codable, Sendable {
    public let resultID: String
    /// Local date string stored by CN; the database does not include a UTC offset.
    public let executedDate: String?
    public let usageHours: UInt32?
    public let usageMinutes: UInt8?
    public var details: CNJSONValue?
}

/// Decode only records linked from this monitor and the CN collection indexes.
/// Unassigned targets and orphan records must not become the current baseline.
enum CNHistoryDecoder {
    private struct Monitor: Decodable {
        let product: String
        let serial: String
        let dbDataVersion: String?
        let applyingTargets: [String?]
        let managementPolicy: Policy?
    }
    private struct Policy: Decodable {
        let type: String?
        let schedule: Schedule?
        struct Schedule: Decodable {
            let type: String?
            let intervalHour: Int?
            var calendar: CNCalibrationSchedule?

            init(from decoder: any Decoder) throws {
                enum Keys: String, CodingKey { case type, intervalHour }
                let values = try decoder.container(keyedBy: Keys.self)
                type = try values.decodeIfPresent(String.self, forKey: .type)
                intervalHour = try values.decodeIfPresent(Int.self, forKey: .intervalHour)
                calendar = try? CNCalibrationSchedule(from: decoder)
            }
        }
    }
    private struct Target: Decodable {
        let id: String
        let name: String?
        let modeName: String?
        let targetSetting: Setting?
        struct Setting: Decodable { let modeType: String? }
    }
    private struct ResultHeader: Decodable { let type: String? }
    private struct Result: Decodable {
        let id: String
        let basicData: Basic?
        struct Basic: Decodable {
            let executedDate: String?
            let executor: Executor?
            let monitorInformation: Usage?
        }
        struct Executor: Decodable {
            let type: String?
            let errorCode: ErrorCode?
        }
        struct Usage: Decodable {
            let usageHours: UInt32?
            let usageMinutes: UInt8?
        }
        enum ErrorCode: Decodable {
            case text(String), number(Int)
            init(from decoder: any Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let text = try? value.decode(String.self) { self = .text(text) }
                else { self = .number(try value.decode(Int.self)) }
            }
            var isZero: Bool {
                switch self {
                case .text(let value): return value == "0"
                case .number(let value): return value == 0
                }
            }
        }
    }

    static func history(model: String, serial: String, sourcePath: String,
                        records: [String: Data], details: CNHistoryDetail = .menu) -> CNCalibrationHistory {
        let monitorID = model + "_" + serial
        guard let data = records["MonitorInformation:" + monitorID] else {
            return CNCalibrationHistory(sourcePath: sourcePath, status: "monitorNotFound")
        }
        do {
            let decoder = JSONDecoder()
            let monitor = try decoder.decode(Monitor.self, from: data)
            guard monitor.product == model, monitor.serial == serial else {
                throw ProbeError("CN monitor record identity does not match the connected monitor")
            }
            var history = CNCalibrationHistory(sourcePath: sourcePath, status: "available")
            if details == .full { history.monitorDetails = try? decoder.decode(CNJSONValue.self, from: data) }
            history.databaseVersion = monitor.dbDataVersion
            if let policy = monitor.managementPolicy {
                let interval = policy.schedule?.intervalHour
                history.managementPolicy = CNManagementPolicy(
                    type: policy.type, scheduleType: policy.schedule?.type,
                    intervalHours: interval.flatMap { $0 > 0 ? $0 : nil },
                    calendarSchedule: policy.schedule?.calendar
                )
            }
            var calibrations: [String: Swift.Result<CNCalibrationRecord?, any Error>] = [:]
            history.colorModes = monitor.applyingTargets.enumerated().map { index, targetID in
                var mode = CNColorModeHistory(modeNumber: index + 1, targetID: targetID, status: "unassigned")
                guard let targetID else { return mode }
                do {
                    guard let targetData = records["Target_" + monitorID + ":" + targetID] else {
                        mode.status = "targetNotFound"
                        return mode
                    }
                    let target = try decoder.decode(Target.self, from: targetData)
                    guard target.id == targetID else { throw ProbeError("CN target identity mismatch") }
                    mode.targetName = target.name
                    mode.modeName = target.modeName
                    mode.modeType = target.targetSetting?.modeType
                    switch details {
                    case .full: mode.targetDetails = try? decoder.decode(CNJSONValue.self, from: targetData)
                    case .menu: mode.targetDetails = try? decoder.decode(CNMenuTargetDetails.self, from: targetData).value
                    case .summary: break
                    }
                    if details != .summary {
                        mode.targetConfigurationDigest = SHA256.hash(data: targetData).map { String(format: "%02x", $0) }.joined()
                    }
                    let collection: String
                    switch mode.modeType {
                    case "Standard":
                        collection = "StandardModeCalibrationResult_" + monitorID
                        mode.historyScope = "sharedStandardModes"
                    case "Calibration":
                        collection = "CalibrationResult_" + targetID
                        mode.historyScope = "target"
                    default:
                        mode.status = "unsupportedModeType"
                        return mode
                    }
                    let calibration = calibrations[collection] ?? Swift.Result {
                        try latestCalibration(collection: collection, records: records, details: details)
                    }
                    calibrations[collection] = calibration
                    mode.lastCalibration = try calibration.get()
                    if let result = mode.lastCalibration {
                        mode.status = result.executedDate != nil && result.usageHours != nil && result.usageMinutes != nil
                            ? "available" : "incompleteCalibration"
                    } else { mode.status = "noCalibration" }
                } catch {
                    mode.status = "invalidRecord"
                    mode.message = String(describing: error)
                }
                return mode
            }
            return history
        } catch {
            return CNCalibrationHistory(sourcePath: sourcePath, status: "invalidRecord", message: String(describing: error))
        }
    }

    private static func latestCalibration(collection: String, records: [String: Data],
                                          details: CNHistoryDetail) throws -> CNCalibrationRecord? {
        guard let indexData = records[collection + "_id_"] else { return nil }
        let decoder = JSONDecoder()
        let resultIDs = try decoder.decode([String].self, from: indexData)
        // CN appends result IDs to this ordered list and searches backwards for a successful calibration.
        for resultID in resultIDs.reversed() {
            guard let data = records[collection + ":" + resultID] else {
                throw ProbeError("CN calibration index references a missing result: \(resultID)")
            }
            guard try decoder.decode(ResultHeader.self, from: data).type == "Calibration" else { continue }
            let result = try decoder.decode(Result.self, from: data)
            guard result.id == resultID else { throw ProbeError("CN calibration result identity mismatch") }
            guard let executor = result.basicData?.executor else {
                throw ProbeError("CN calibration result has no executor information")
            }
            let succeeded = executor.type == "CN" ? (executor.errorCode?.isZero ?? true)
                : executor.type == "Self" && executor.errorCode?.isZero == true
            guard succeeded else { continue }
            let date = result.basicData?.executedDate
            if let date { try validateDate(date) }
            let usage = result.basicData?.monitorInformation
            if let minutes = usage?.usageMinutes, minutes >= 60 {
                throw ProbeError("Invalid calibration usage minutes: \(minutes)")
            }
            let savedDetails: CNJSONValue?
            switch details {
            case .full: savedDetails = try? decoder.decode(CNJSONValue.self, from: data)
            case .menu: savedDetails = try? decoder.decode(CNMenuResultDetails.self, from: data).value
            case .summary: savedDetails = nil
            }
            return CNCalibrationRecord(resultID: resultID, executedDate: date,
                                       usageHours: usage?.usageHours, usageMinutes: usage?.usageMinutes,
                                       details: savedDetails)
        }
        return nil
    }

    private static func validateDate(_ text: String) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        guard text.utf8.count == 19, let date = formatter.date(from: text), formatter.string(from: date) == text else {
            throw ProbeError("Invalid CN calibration date: \(text)")
        }
    }
}
