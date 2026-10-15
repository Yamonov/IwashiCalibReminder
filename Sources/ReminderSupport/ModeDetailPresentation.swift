import EIZOHID
import Foundation

public struct ModeDetailEntry: Sendable, Equatable {
    public let label: String
    public let value: String
    public init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value ?? "記録なし"
    }
    public var title: String { "\(label)：\(value)" }
}

public struct ModeDetailSection: Sendable {
    public let title: String
    public let entries: [ModeDetailEntry]
    public let inline: Bool
    public init(_ title: String, _ entries: [ModeDetailEntry], inline: Bool = false) {
        self.title = title
        self.entries = entries
        self.inline = inline
    }
}

public struct ModeDetailPresentation: Sendable {
    public let sections: [ModeDetailSection]
    public let rawRecords: [(name: String, value: CNJSONValue)]

    public init(report: MonitorUsageReport, mode: CNColorModeHistory, timeZone: TimeZone = .current) {
        let content = ModeDetailContent(report: report, mode: mode, timeZone: timeZone)
        sections = content.sections
        rawRecords = content.rawRecords
    }
}

/// Keeps the saved target and the previous measurement in separate sections.
private struct ModeDetailContent {
    let report: MonitorUsageReport
    let mode: CNColorModeHistory
    let timeZone: TimeZone

    private var reading: MonitorReading { report.monitor }
    private var history: CNCalibrationHistory { report.calibrationHistory }
    private var countdown: CNModeCountdown? {
        report.calibrationCountdown.colorModes.first { $0.modeNumber == mode.modeNumber }
    }
    private var calibration: CNCalibrationRecord? { mode.lastCalibration }
    private var target: CNJSONValue? { mode.targetDetails }
    private var settings: CNJSONValue? { target?["targetSetting"] }
    private var result: CNJSONValue? { calibration?.details }
    private var basic: CNJSONValue? { result?["basicData"] }

    var sections: [ModeDetailSection] {
        var sections = [modeSection, timingSection, targetSection]
        if let advanced = settings?["advancedSettings"] {
            sections.append(.init("目標の詳細設定", Self.flatten(advanced)))
        }
        sections += [measurementSection, measurementConditions, storedProfileSection,
                     profileSettingsSection, identificationSection]
        if let message = mode.message {
            sections.append(.init("記録について", [.init("詳細", message)]))
        }
        return sections
    }

    var rawRecords: [(name: String, value: CNJSONValue)] {
        [("モニター情報", history.monitorDetails), ("調整目標", target), ("前回の調整結果", result)]
            .compactMap { name, value in value.map { (name, $0) } }
    }

    private var modeSection: ModeDetailSection {
        let modeName = mode.modeName ?? (mode.modeType == "Standard" ? mode.targetName : nil) ?? "モード \(mode.modeNumber)"
        let badge = mode.modeType == "Standard" ? "STD" : mode.modeType == "Calibration" ? "ADV" : "不明"
        return .init("モード", [
            .init("モニター", "\(reading.model) / S/N \(reading.serialNumber)"),
            .init("モード", "\(mode.modeNumber) · \(modeName) [\(badge)]"),
            .init("調整目標", mode.targetName),
            .init("有効状態", reading.modeAvailability?.enabledModeNumbers.contains(mode.modeNumber) == true ? "有効" : "取得できません"),
            .init("調整記録", ModeDetailText.recordStatus(mode.status)),
            .init("記録の範囲", mode.historyScope == "sharedStandardModes" ? "STDモード共通の調整記録" : mode.historyScope == "target" ? "この調整目標の記録" : nil)
        ], inline: true)
    }

    private var timingSection: ModeDetailSection {
        let policy = history.managementPolicy
        let interval: Int64? = policy?.intervalHours.flatMap {
            let (value, overflow) = Int64($0).multipliedReportingOverflow(by: 60)
            return $0 > 0 && !overflow ? value : nil
        }
        let baseline = calibration.flatMap { ModeDetailText.usageMinutes(hours: $0.usageHours, minutes: $0.usageMinutes) }
        let current = Int64(reading.usageHours) * 60 + Int64(reading.usageMinutes)
        let deadline: Int64? = {
            guard countdown?.remainingMinutes != nil, let baseline, let interval else { return nil }
            let (value, overflow) = baseline.addingReportingOverflow(interval)
            return overflow ? nil : value
        }()
        let nextDate = ModeDetailText.nextDateDescription(readAt: reading.readAt, remainingMinutes: countdown?.remainingMinutes, timeZone: timeZone)
        return .init("使用時間・次回の調整", [
            .init("残り使用時間", countdown?.remainingMinutes.map(ReminderText.remaining)),
            .init("現在の累積", ReminderText.duration(current)),
            .init("前回調整時の累積", baseline.map(ReminderText.duration)),
            .init("調整後の使用", countdown?.elapsedMinutes.map(ReminderText.duration)),
            .init("調整間隔", interval.map(ReminderText.duration)),
            .init("次回の累積時間", deadline.map { ReminderText.duration($0) + " 到達時" }),
            .init("前回実施日時", calibration?.executedDate.flatMap(ModeDetailText.longCNDate)),
            .init("次回の目安", nextDate),
            .init("日時の前提", "取得時点から連続使用した場合。使用を止めると到達日は延びます"),
            .init("管理方法", policy?.type.map(ModeDetailText.term)),
            .init("スケジュール", policy?.scheduleType.map(ModeDetailText.term))
        ], inline: true)
    }

    private var targetSection: ModeDetailSection {
        .init("調整目標（現在の保存設定）", [
            .init("輝度", ModeDetailText.targetValue(settings?["brightness"])),
            .init("黒レベル", ModeDetailText.targetValue(settings?["blackLevel"])),
            .init("白色点", ModeDetailText.targetValue(settings?["whitePoint"])),
            .init("ガンマ / EOTF", ModeDetailText.targetValue(settings?["gamma"])),
            .init("色域", ModeDetailText.targetValue(settings?["gamut"])),
            .init("色域クリッピング", settings?["gamut"]?["clipping"]?.boolean.map(ModeDetailText.onOff)),
            .init("調整方法", settings?["calibrationPolicy"]?.string.map(ModeDetailText.term)),
            .init("Limited 109%最適化", settings?["optimizeForLimited109"]?.boolean.map(ModeDetailText.onOff))
        ], inline: true)
    }

    private var measurementSection: ModeDetailSection {
        let usesCMF = !(result?["measurementDataCMF"]?.array ?? []).isEmpty
        let measurements = (usesCMF ? result?["measurementDataCMF"] : result?["measurementData"])?.array ?? []
        func patch(_ r: Double, _ g: Double, _ b: Double) -> CNJSONValue? {
            measurements.first { $0["RGB"]?["R"]?.number == r && $0["RGB"]?["G"]?.number == g && $0["RGB"]?["B"]?.number == b }?["XYZ"]
        }
        let white = patch(1, 1, 1)
        let black = patch(0, 0, 0)
        let contrast: String? = {
            guard result?["hasValidMeasuredBlackValue"]?.boolean != false else { return nil }
            guard let w = white?["Y"]?.number, let b = black?["Y"]?.number, w > 0, b > 0 else { return nil }
            let ratio = w / b
            guard ratio.isFinite else { return nil }
            return ModeDetailText.number(ratio, digits: 1) + " : 1"
        }()
        let measuredTitle = mode.historyScope == "sharedStandardModes" ? "前回の測定結果（STD共通）" : "前回の測定結果"
        return .init(measuredTitle, [
            .init("データの基準", usesCMF ? "調整時の等色関数を適用した測定記録" : "CNに保存された測定記録"),
            .init("白の輝度", white?["Y"]?.number.map { ModeDetailText.number($0, digits: 4) + " cd/m²" }),
            .init("白色点", ModeDetailText.xy(white)),
            .init("黒の輝度", black?["Y"]?.number.map { ModeDetailText.number($0, digits: 4) + " cd/m²" }),
            .init("コントラスト比（計算）", contrast),
            .init("R原色", ModeDetailText.xy(patch(1, 0, 0))),
            .init("G原色", ModeDetailText.xy(patch(0, 1, 0))),
            .init("B原色", ModeDetailText.xy(patch(0, 0, 1))),
            .init("調整直後の白", ModeDetailText.whiteDescription(result?["justCalibratedWhite"]?["XYZ"])),
            .init("最大白輝度の記録", result?["maxWhite"]?.number.map { ModeDetailText.number($0, digits: 4) + " cd/m²" }),
            .init("黒の測定値の有効性", result?["hasValidMeasuredBlackValue"]?.boolean.map { $0 ? "有効" : "無効" })
        ])
    }

    private var measurementConditions: ModeDetailSection {
        let sensor = basic?["sensorInformation"]
        return .init("調整・測定条件", [
            .init("実行元", basic?["executor"]?["type"]?.string.map(ModeDetailText.term)),
            .init("調整ソフトのバージョン", basic?["executor"]?["softwareVersion"]?.string),
            .init("等色関数", sensor?["colorMatchingFunction"]?.string.map(ModeDetailText.term)),
            .init("測定器ID", sensor?["colorSensorID"].map(ModeDetailText.scalar)),
            .init("測定器シリアル", sensor?["colorSensorSerial"].map(ModeDetailText.scalar)),
            .init("測定器の補正", sensor?["colorSensorCorrection"]?.string.map(ModeDetailText.term)),
            .init("DUE優先設定", basic?["monitorInformation"]?["duePriority"]?.string.map(ModeDetailText.term))
        ])
    }

    private var storedProfileSection: ModeDetailSection {
        let stored = target?["profileData"]?["storedData"]
        let path = stored?["path"]?.string
        return .init("ICCプロファイル（保存記録）", [
            .init("ファイル名", path.map { URL(fileURLWithPath: $0).lastPathComponent }),
            .init("パス", path),
            .init("ICCバージョン", stored?["profileVersion"]?.string),
            .init("トーンカーブ", stored?["toneCurve"]?.string),
            .init("黒レベルの反映", stored?["reflectBlackLevels"]?.boolean.map(ModeDetailText.onOff))
        ])
    }

    private var profileSettingsSection: ModeDetailSection {
        let profilePolicy = target?["profilePolicy"]
        return .init("ICC作成設定・目標の保護", [
            .init("ICCバージョン", profilePolicy?["profileVersion"]?.string),
            .init("トーンカーブ", profilePolicy?["toneCurve"]?.string),
            .init("黒レベルの反映", profilePolicy?["reflectBlackLevels"]?.boolean.map(ModeDetailText.onOff)),
            .init("プロファイル更新", target?["profileUpdateRule"]?.string.map(ModeDetailText.term)),
            .init("目標名をプロファイル名に使用", target?["useTargetNameAsProfileName"]?.boolean.map(ModeDetailText.onOff)),
            .init("目標の保護", target?["protection"]?.boolean.map(ModeDetailText.onOff))
        ])
    }

    private var identificationSection: ModeDetailSection {
        .init("情報の取得・識別", [
            .init("取得日時", ModeDetailText.isoDate(reading.readAt).map { ModeDetailText.longDate($0, timeZone: timeZone) }),
            .init("HID取得処理時間", ModeDetailText.number(reading.elapsedMilliseconds, digits: 1) + " ms"),
            .init("USB Vendor / Product", "\(reading.vendorID) / \(reading.productID)"),
            .init("USB接続位置", reading.locationID),
            .init("使用時間の問い合わせ識別子", reading.usageIdentifier),
            .init("使用時間の応答", reading.rawPayload),
            .init("モード有効フラグ", reading.modeAvailability?.rawPayload),
            .init("CNデータバージョン", history.databaseVersion),
            .init("CNデータベース", history.sourcePath),
            .init("目標ID", mode.targetID),
            .init("調整結果ID", calibration?.resultID)
        ])
    }

    private static func flatten(_ value: CNJSONValue, prefix: String = "") -> [ModeDetailEntry] {
        let names = ["hue": "色相", "saturation": "彩度", "lightness": "明度", "blackLevel": "黒レベル補正",
                     "sixColors": "6色調整", "red": "R", "green": "G", "blue": "B", "cyan": "C", "magenta": "M", "yellow": "Y"]
        guard let object = value.object else { return [.init(prefix, ModeDetailText.scalar(value))] }
        return object.sorted { $0.key < $1.key }.flatMap { key, value in
            let label = (prefix.isEmpty ? "" : prefix + " / ") + (names[key] ?? key)
            return flatten(value, prefix: label)
        }
    }
}
