import EIZOHID
import Foundation

/// Synthetic data only. Demo launch never checks CN, reads its DB, or opens USB HID.
public enum DemoData {
    public static func reports() throws -> [MonitorUsageReport] {
        let definitions = [(2, "Adobe RGB"), (3, "sRGB"), (5, "Display P3"), (7, "Print"), (8, "PrintBlack")]
        let modes: [[String: Any]] = definitions.map { number, name in
            ["modeNumber": number, "targetID": "demo-\(number)", "targetName": "\(name) Target",
             "modeName": name, "modeType": number <= 5 ? "Standard" : "Calibration", "status": "available",
             "historyScope": number <= 5 ? "sharedStandardModes" : "target",
             "targetDetails": ["targetSetting": [
                "brightness": ["type": "Candela", "value": 80],
                "whitePoint": ["type": "Standard", "value": "D50"],
                "gamma": ["type": "Gamma", "value": 2.2],
                "gamut": ["type": "Native", "clipping": false], "calibrationPolicy": "Standard"
             ], "profileData": ["storedData": ["path": "/demo/CS2731-\(name).icc", "profileVersion": "4.2", "toneCurve": "LUT"]]],
             "lastCalibration": ["resultID": "demo-result-\(number)", "executedDate": "2026-10-01 18:49:00",
                                 "usageHours": number == 8 ? 380 : 403, "usageMinutes": 0,
                                 "details": ["basicData": ["executor": ["type": "CN", "softwareVersion": "DEMO"],
                                      "sensorInformation": ["colorMatchingFunction": "CIE1964_10Deg", "colorSensorID": 20]],
                                      "measurementData": [
                                        ["RGB": ["R": 1, "G": 1, "B": 1], "XYZ": ["Y": 80, "x": 0.3456, "y": 0.3584]],
                                        ["RGB": ["R": 0, "G": 0, "B": 0], "XYZ": ["Y": 0.1, "x": 0.3, "y": 0.3]]
                                      ]]]]
        }
        let reading: [String: Any] = [
            "model": "CS2731", "serialNumber": "DEMO", "vendorID": "0x056D", "productID": "0x4048",
            "locationID": "demo", "usageHours": 515, "usageMinutes": 30, "usageIdentifier": "demo",
            "rawPayload": "", "readAt": ISO8601DateFormatter().string(from: .now), "elapsedMilliseconds": 0,
            "modeAvailability": ["status": "available", "modeCount": 10, "enabledModeNumbers": definitions.map(\.0)]
        ]
        let history: [String: Any] = ["sourcePath": "demo", "status": "available", "colorModes": modes,
                                    "managementPolicy": ["type": "CNCalibration", "scheduleType": "EveryUsageTime", "intervalHours": 200]]
        let decoder = JSONDecoder()
        let monitor = try decoder.decode(MonitorReading.self, from: JSONSerialization.data(withJSONObject: reading))
        let calibration = try decoder.decode(CNCalibrationHistory.self, from: JSONSerialization.data(withJSONObject: history))
        return [MonitorUsageReport(monitor: monitor, calibrationHistory: calibration)]
    }
}
