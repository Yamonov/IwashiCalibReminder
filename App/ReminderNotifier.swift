import EIZOHID
import Foundation
import Observation
import ReminderSupport
import UserNotifications

@Observable @MainActor
final class ReminderNotifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var notice: String?
    @ObservationIgnored private let preferences: ReminderPreferences
    @ObservationIgnored private weak var model: ReminderModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var delivering = false
    @ObservationIgnored private var authorizationTask: Task<Bool, Never>?

    init(preferences: ReminderPreferences, model: ReminderModel, defaults: UserDefaults, isDemo: Bool) {
        self.preferences = preferences; self.model = model; self.defaults = defaults; self.isDemo = isDemo
        super.init()
    }

    func prepare() async {
        guard !isDemo else { return }
        UNUserNotificationCenter.current().delegate = self
        if await authorize() { await deliverLatest() }
    }

    private func authorize() async -> Bool {
        if let authorizationTask { return await authorizationTask.value }
        let task = Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            do {
                let allowed: Bool
                if status == .notDetermined { allowed = try await center.requestAuthorization(options: [.alert]) }
                else { allowed = status == .authorized || status == .provisional }
                self?.notice = allowed ? nil : "macOSの通知が許可されていません"
                return allowed
            } catch {
                self?.notice = "macOSの通知を利用できません"
                return false
            }
        }
        authorizationTask = task
        let allowed = await task.value
        authorizationTask = nil
        return allowed
    }

    func deliverLatest() async {
        guard !isDemo, !delivering, model?.phase == .ready else { return }
        delivering = true
        defer { delivering = false }
        let initialMenu = ReminderMenuData(reports: model?.reports ?? [])
        let previous = Set(defaults.stringArray(forKey: "deliveredCalibrationReminders") ?? [])
        guard !ReminderNotificationRules.pending(menu: initialMenu, thresholdMinutes: preferences.thresholdMinutes,
                                                  deliveredKeys: previous).isEmpty, await authorize() else { return }
        // A permission dialog can remain open while the data or preferences change.
        // Re-check the latest successful reading after that asynchronous boundary.
        guard model?.phase == .ready else { return }
        let menu = ReminderMenuData(reports: model?.reports ?? [])
        let delivered = Set(defaults.stringArray(forKey: "deliveredCalibrationReminders") ?? [])
        let rows = ReminderNotificationRules.pending(menu: menu, thresholdMinutes: preferences.thresholdMinutes,
                                                     deliveredKeys: delivered)
        guard !rows.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = rows.contains { ($0.remainingMinutes ?? 1) < 0 }
            ? "再キャリブレーションの期限を過ぎています" : "再キャリブレーションの時期が近づいています"
        content.body = rows.prefix(8).map {
            "\(menu.monitorLabel(for: $0) ?? $0.monitorName) \($0.modeName)：\($0.remainingText)"
        }.joined(separator: "\n")
        if rows.count > 8 { content.body += "\nほか\(rows.count - 8)モード" }
        content.threadIdentifier = "calibration-reminder"
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
            let updated = delivered.union(rows.compactMap(ReminderNotificationRules.key))
            defaults.set(updated.sorted(), forKey: "deliveredCalibrationReminders")
            notice = nil
        } catch { notice = "通知を送信できませんでした" }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
}
