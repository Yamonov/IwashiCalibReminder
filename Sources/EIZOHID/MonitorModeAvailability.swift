import Foundation

public struct MonitorModeAvailability: Codable, Sendable {
    public let status: String
    public let modeCount: Int?
    public let enabledModeNumbers: [Int]
    public let rawPayload: String?
    public let message: String?

    /// EmCtrlGetModeSkip converts zero to "skip"; CN negates that to obtain "enable".
    /// This usage therefore contains one enable byte per zero-based monitor mode.
    static func decode(_ payload: [UInt8]) throws -> MonitorModeAvailability {
        guard !payload.isEmpty, payload.count <= 32 else { throw ProbeError("Unsupported mode-enable payload length") }
        return MonitorModeAvailability(status: "available", modeCount: payload.count,
                                       enabledModeNumbers: payload.enumerated().compactMap { $0.element != 0 ? $0.offset + 1 : nil },
                                       rawPayload: hex(payload), message: nil)
    }

    static func unavailable(_ message: String) -> MonitorModeAvailability {
        MonitorModeAvailability(status: "unavailable", modeCount: nil, enabledModeNumbers: [], rawPayload: nil, message: message)
    }
}

extension CNCalibrationHistory {
    public func selectingModes(using availability: MonitorModeAvailability?, includeAllModes: Bool = false) -> CNCalibrationHistory {
        var result = self
        result.modeScope = includeAllModes ? "allSavedModes" : "enabledModes"
        guard !includeAllModes, status == "available" else { return result }
        guard let availability, availability.status == "available", let count = availability.modeCount,
              count >= (colorModes.map(\.modeNumber).max() ?? 0) else {
            return CNCalibrationHistory(sourcePath: sourcePath, status: "modeSelectionUnavailable",
                                        message: availability?.message ?? "Monitor mode-enable state was not obtained for all saved modes",
                                        databaseVersion: databaseVersion, modeScope: "enabledModes", managementPolicy: managementPolicy,
                                        monitorDetails: monitorDetails)
        }
        let enabled = Set(availability.enabledModeNumbers)
        result.colorModes = colorModes.filter { enabled.contains($0.modeNumber) }
        return result
    }
}
