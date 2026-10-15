import Foundation

public struct CNStoredMonitor: Encodable {
    public let model: String
    public let serialNumber: String
    public let calibrationHistory: CNCalibrationHistory
}

public struct CNDatabaseContents: Encodable {
    public let sourcePath: String
    public let status: String
    public let message: String?
    private let records: [String: Data]

    enum CodingKeys: String, CodingKey { case sourcePath, status, message, monitors }

    init(sourcePath: String, status: String, message: String? = nil, records: [String: Data] = [:]) {
        self.sourcePath = sourcePath
        self.status = status
        self.message = message
        self.records = records
    }

    public func history(model: String, serial: String) -> CNCalibrationHistory {
        guard status == "available" else {
            return CNCalibrationHistory(sourcePath: sourcePath, status: status, message: message)
        }
        return CNHistoryDecoder.history(model: model, serial: serial, sourcePath: sourcePath, records: records)
    }

    /// These are saved CN records, not an enumeration of currently connected monitors.
    public var storedMonitors: [CNStoredMonitor] {
        records.keys.filter { $0.hasPrefix("MonitorInformation:") }.sorted().compactMap { key in
            let identity = key.dropFirst("MonitorInformation:".count)
            guard let separator = identity.lastIndex(of: "_") else { return nil }
            let model = String(identity[..<separator])
            let serial = String(identity[identity.index(after: separator)...])
            var savedHistory = history(model: model, serial: serial)
            savedHistory.modeScope = "allSavedModes"
            return CNStoredMonitor(model: model, serialNumber: serial, calibrationHistory: savedHistory)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourcePath, forKey: .sourcePath)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(message, forKey: .message)
        try values.encode(storedMonitors, forKey: .monitors)
    }
}

public enum CNDatabase {
    public static let defaultPath = "/Library/Application Support/EIZO/ColorNavigator 7/db.0"

    /// Reads original files through Foundation only. No temporary DB, LevelDB library, or CLI.
    public static func read(path: String = defaultPath) -> CNDatabaseContents {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        do {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: source.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return CNDatabaseContents(sourcePath: source.path, status: "databaseNotFound")
            }
            let values = try LevelDBDirectReader.read(directory: source)
            var records: [String: Data] = [:]
            let prefixes = ["MonitorInformation:", "Target_", "CalibrationResult_", "StandardModeCalibrationResult_"]
            for (keyData, value) in values {
                if let key = String(data: keyData, encoding: .utf8), prefixes.contains(where: key.hasPrefix) {
                    records[key] = value
                }
            }
            return CNDatabaseContents(sourcePath: source.path, status: "available", records: records)
        } catch {
            return CNDatabaseContents(sourcePath: source.path, status: "unavailable", message: String(describing: error))
        }
    }
}
