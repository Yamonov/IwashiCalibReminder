import EIZOHID
import Foundation

public struct ModeDetailEntry: Sendable, Equatable {
    public let label: String
    public let value: String
    public init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value ?? L10n.text("Not recorded")
    }
}

public struct ModeMenuPresentation: Sendable {
    public let badge: String
    public let name: String
    public let cardLines: [String]
    public let entries: [ModeDetailEntry]
    public let gamutCoordinates: [ModeDetailEntry]
    public let profilePath: String?
    public let profileEntries: [ModeDetailEntry]
    public let usesSpecifiedProfile: Bool

    public init(report: MonitorUsageReport, mode: CNColorModeHistory, at date: Date = .now,
                timeZone: TimeZone = .current) {
        let standard = mode.modeType == "Standard"
        badge = standard ? "STD" : mode.modeType == "Calibration" ? "ADV" : "—"
        name = mode.modeName ?? (standard ? mode.targetName : nil) ?? L10n.text("Mode %ld", mode.modeNumber)
        let target = mode.targetDetails
        let settings = target?["targetSetting"]
        let result = mode.lastCalibration?.details
        let basic = result?["basicData"]
        let white = Self.measuredWhite(result)
        let countdown = report.calibrationCountdown.colorModes.first { $0.modeNumber == mode.modeNumber }
        let policy = report.calibrationHistory.managementPolicy
        var lines: [String] = []
        if policy?.type != "None" {
            let previous = mode.lastCalibration?.executedDate.flatMap { CNDate.local($0, timeZone: timeZone) }
                .map { Self.dateText($0, timeZone: timeZone) } ?? L10n.text("Previous calibration date unknown")
            if let countdown, let remaining = countdown.remaining(at: date) {
                if countdown.basis == "calendar", let deadline = countdown.nextCalibrationDate.flatMap(CNDate.iso) {
                    lines.append(L10n.text("%1$@ – %2$@", previous, Self.dateText(deadline, timeZone: timeZone)))
                    let interval = policy?.calendarSchedule.map { L10n.text(" (%@)", Self.calendarInterval($0)) } ?? ""
                    lines.append(Self.remaining(remaining) + interval)
                } else {
                    let interval = policy?.intervalHours.map { L10n.text(" (every %ld h)", $0) } ?? ""
                    lines.append(L10n.text("Last: %1$@ — %2$@%3$@", previous, Self.remaining(remaining), interval))
                    if remaining >= 0, let predicted = countdown.predictedCalibrationDate.flatMap(CNDate.iso) {
                        lines.append(L10n.text("Estimated: %@", Self.dateText(predicted, timeZone: timeZone)))
                    }
                }
                if standard, let elapsed = countdown.elapsedMinutes {
                    lines.append(L10n.text("(used %@)", Self.approximateHours(elapsed)))
                }
            } else {
                lines.append(previous)
                lines.append(L10n.text("Remaining time is unknown"))
            }
        }
        cardLines = lines
        func entry(_ label: String, _ value: String?) -> ModeDetailEntry { .init(label, value ?? "—") }
        var values: [ModeDetailEntry] = []
        if standard { values.append(entry(L10n.text("Calibration target"), mode.targetName)) }
        let brightness = Self.brightness(settings?["brightness"])
        if !standard, let measured = white?["Y"]?.number {
            let goal = brightness.map { L10n.text(" (%@)", $0.replacingOccurrences(of: " ", with: "")) } ?? ""
            values.append(entry(L10n.text("Brightness"), Self.number(measured, digits: 1) + L10n.text(" cd/m²") + goal))
        } else { values.append(entry(L10n.text("Brightness"), brightness)) }
        values.append(entry(L10n.text("White point"), Self.whitePoint(settings?["whitePoint"], measured: standard ? nil : white)))
        let gamma = settings?["gamma"]
        values.append(entry(L10n.text("Gamma"), gamma?["type"]?.string == "Gamma"
            ? gamma?["value"]?.number.map { Self.number($0, digits: 2) } : gamma?["value"]?.string ?? gamma?["type"]?.string))
        if !standard { values.append(entry(L10n.text("Calibration method"), settings?["calibrationPolicy"]?.string.map(ModeDetailText.term))) }
        let gamut = settings?["gamut"]
        let coordinates = Self.gamutRows(gamut)
        gamutCoordinates = coordinates
        values.append(entry(L10n.text("Gamut"), coordinates.isEmpty ? gamut?["value"]?.string ?? gamut?["type"]?.string : ""))
        values.append(entry(L10n.text("Gamut clipping"), gamut?["clipping"]?.boolean.map(ModeDetailText.onOff)))
        if !standard {
            values.append(entry(L10n.text("Color matching function"), basic?["sensorInformation"]?["colorMatchingFunction"]?.string.map {
                ModeDetailText.term($0).replacingOccurrences(of: " / ", with: " ")
            }))
        }
        if let sensor = Self.sensorName(basic) { values.append(entry(L10n.text("Measurement device"), sensor)) }
        entries = values
        let profile = target?["profileData"]
        let concrete = profile?["concreteBinary"]
        usesSpecifiedProfile = concrete?.object != nil
        // CN stores the imported ICC bytes in concreteBinary, and the actual
        // installed file's path in storedData; the import source path is not kept.
        profilePath = profile?["storedData"]?["path"]?.string
        let stored = profile?["storedData"]
        let profilePolicy = target?["profilePolicy"]
        var profileValues: [ModeDetailEntry] = []
        if !usesSpecifiedProfile {
            profileValues.append(entry(L10n.text("Tone curve"), stored?["toneCurve"]?.string ?? profilePolicy?["toneCurve"]?.string))
            if !standard {
                profileValues.append(entry(L10n.text("Version"), stored?["profileVersion"]?.string ?? profilePolicy?["profileVersion"]?.string))
                profileValues.append(entry(L10n.text("Include black level in tone curve"), (stored?["reflectBlackLevels"]?.boolean
                    ?? profilePolicy?["reflectBlackLevels"]?.boolean).map { $0 ? L10n.text("Enabled") : L10n.text("Disabled") }))
            }
            profileValues.append(entry(L10n.text("Update profile"),
                target?["profileUpdateRule"]?.string.map { $0 == "Everytime" ? L10n.text("Enabled") : $0 == "Concrete" ? L10n.text("Disabled") : "—" }))
        }
        profileEntries = profileValues
    }

    public static func approximateHours(_ minutes: Int64) -> String {
        let hours = minutes.magnitude / 60 + (minutes.magnitude % 60 >= 30 ? 1 : 0)
        return L10n.text("About %llu h", hours)
    }
    public static func remaining(_ minutes: Int64) -> String {
        minutes < 0 ? L10n.text("%@ overdue", approximateHours(minutes)) : L10n.text("Remaining: %@", approximateHours(minutes))
    }
    public static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
    private static func calendarInterval(_ schedule: CNCalibrationSchedule) -> String {
        switch schedule.type {
        case "Daily": L10n.text("Daily")
        case "Weekly": schedule.intervalWeek.map { $0 == 1 ? L10n.text("Weekly") : L10n.text("Every %ld weeks", $0) } ?? L10n.text("Weekly")
        case "Monthly": schedule.intervalMonth.map { $0 == 1 ? L10n.text("Monthly") : L10n.text("Every %ld months", $0) } ?? L10n.text("Monthly")
        case "Quarterly": L10n.text("Every 3 months")
        case "SemiAnnual": L10n.text("Every 6 months")
        case "Annual": L10n.text("Yearly")
        default: L10n.text("Unknown interval")
        }
    }
    private static func number(_ value: Double, digits: Int) -> String { ModeDetailText.number(value, digits: digits) }
    private static func brightness(_ value: CNJSONValue?) -> String? {
        if value?["type"]?.string == "Candela", let n = value?["value"]?.number {
            return number(n, digits: n.rounded() == n ? 0 : 1) + L10n.text(" cd/m²")
        }
        return ModeDetailText.targetValue(value)
    }
    private static func xy(_ value: CNJSONValue?) -> String? {
        guard let x = value?["x"]?.number, let y = value?["y"]?.number else { return nil }
        return "x:" + number(x, digits: 4) + " y:" + number(y, digits: 4)
    }
    private static func whitePoint(_ value: CNJSONValue?, measured: CNJSONValue?) -> String? {
        if let coordinates = xy(value?["value"] ?? value) { return coordinates }
        let goal = value?["value"]?.string ?? value?["value"]?.number.map { number($0, digits: 0) + "K" }
        if let x = measured?["x"]?.number, let y = measured?["y"]?.number,
           let kelvin = CorrelatedColorTemperature.kelvin(x: x, y: y) {
            return number(kelvin, digits: 0) + "K" + (goal.map { L10n.text(" (%@)", $0) } ?? "")
        }
        if let measured = xy(measured) { return measured + (goal.map { L10n.text(" (%@)", $0) } ?? "") }
        return goal
    }
    private static func measuredWhite(_ result: CNJSONValue?) -> CNJSONValue? {
        if let white = result?["justCalibratedWhite"]?["XYZ"], white.object != nil { return white }
        for key in ["measurementDataCMF", "measurementData"] {
            let data = result?[key]?.array ?? []
            if let white = data.first(where: { $0["RGB"]?["R"]?.number == 1 && $0["RGB"]?["G"]?.number == 1
                && $0["RGB"]?["B"]?.number == 1 })?["XYZ"], white.object != nil { return white }
        }
        return nil
    }
    private static func gamutRows(_ gamut: CNJSONValue?) -> [ModeDetailEntry] {
        let value = gamut?["value"] ?? gamut
        let rows = [("R", "red"), ("G", "green"), ("B", "blue")].compactMap { label, key -> ModeDetailEntry? in
            guard let coordinates = value?[key] ?? value?[label], let x = coordinates["x"]?.number,
                  let y = coordinates["y"]?.number else { return nil }
            return ModeDetailEntry(label, number(x, digits: 4) + "\t" + number(y, digits: 4))
        }
        return rows.count == 3 ? rows : []
    }
    private static func sensorName(_ basic: CNJSONValue?) -> String? {
        let sensor = basic?["sensorInformation"]
        if basic?["executor"]?["type"]?.string == "Self" { return L10n.text("Built-in monitor sensor") }
        if let name = sensor?["name"]?.string, !name.isEmpty { return name }
        guard let number = sensor?["colorSensorID"]?.number, number.rounded() == number,
              (1...999).contains(number) else { return nil }
        let names = [1:"i1Pro", 2:"i1Display", 3:"DTP94", 4:"Spyder2", 5:"Spyder3", 6:"ColorMunki",
            7:"EX1", 8:"Chroma5", 10:L10n.text("Built-in monitor sensor"), 11:"i1Display Pro", 12:"Spyder4", 13:"EX2",
            14:"DISCUS", 15:"i1Pro / i1Pro 2", 16:"ColorMunki Smile", 17:"Spyder5", 18:"EX3",
            20:"i1Studio/ColorCheckerStudio", 21:"SpyderX", 22:"EX4", 23:"i1Pro 3", 24:"MYIRO-1",
            26:"Spyder X2", 27:"EX5", 28:"SpyderPro", 29:"Spyder"]
        return names[Int(number)] ?? L10n.text("Sensor ID %ld", Int(number))
    }
}
