import AppKit
import EIZOHID
import Foundation
import Observation
import ReminderSupport
import UserNotifications

@MainActor
protocol ReminderNotificationService {
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func openSettings() -> Bool
}

@MainActor
private struct SystemReminderNotificationService: ReminderNotificationService {
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        UNUserNotificationCenter.current().delegate = delegate
    }
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
    func openSettings() -> Bool {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        if NSWorkspace.shared.open(pane) { return true }
        guard let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return false }
        return NSWorkspace.shared.open(settings)
    }
}

@Observable @MainActor
final class ReminderNotifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorizationStatus: UNAuthorizationStatus?
    private(set) var isBusy = false
    private var authorizationFailure: String?
    private var deliveryFailure: String?
    @ObservationIgnored private let preferences: ReminderPreferences
    @ObservationIgnored private weak var model: ReminderModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let service: any ReminderNotificationService
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration: UUID?
    @ObservationIgnored private var permissionCheckPending = false
    @ObservationIgnored private var permissionRequestPending = false
    @ObservationIgnored private var deliveryPending = false
    @ObservationIgnored private var stopped = false

    private struct Delivery {
        let request: UNNotificationRequest
        let keys: Set<String>
    }

    init(preferences: ReminderPreferences, model: ReminderModel, defaults: UserDefaults,
         service: (any ReminderNotificationService)? = nil) {
        self.preferences = preferences
        self.model = model
        self.defaults = defaults
        self.service = service ?? SystemReminderNotificationService()
        super.init()
    }

    deinit { operationTask?.cancel() }

    var permissionStatusText: String {
        guard let authorizationStatus else { return L10n.text("Notifications: Checking…") }
        switch authorizationStatus {
        case .notDetermined: return L10n.text("Notifications: Not requested")
        case .denied: return L10n.text("Notifications: Not allowed")
        case .authorized: return L10n.text("Notifications: Allowed")
        case .provisional: return L10n.text("Notifications: Delivered quietly")
        @unknown default: return L10n.text("Notifications: Unavailable")
        }
    }

    var permissionActionTitle: String {
        switch authorizationStatus {
        case .notDetermined?: L10n.text("Allow notifications…")
        case .denied?, .authorized?, .provisional?: L10n.text("Notification settings…")
        default: L10n.text("Check again")
        }
    }

    var notice: String? {
        if let authorizationFailure { return authorizationFailure }
        if authorizationStatus == .denied {
            return L10n.text("macOS notifications are not allowed")
        }
        if authorizationStatus == .notDetermined {
            return L10n.text("Notification permission has not been requested")
        }
        return deliveryFailure
    }

    var settingsNotice: String? {
        if let authorizationFailure { return authorizationFailure }
        if authorizationStatus == .denied {
            return L10n.text("Enable notifications for IwashiCalibReminder in System Settings > Notifications.")
        }
        if authorizationStatus == .notDetermined {
            return L10n.text("Allow notifications to receive calibration reminders.")
        }
        return deliveryFailure
    }

    /// Reading the OS state never requests permission unless the caller opts in.
    /// Startup uses the same initial-wait gate as monitor acquisition for prompting.
    func checkAuthorization(requestIfUndetermined: Bool = false) {
        guard !stopped else { return }
        permissionCheckPending = true
        permissionRequestPending = permissionRequestPending || requestIfUndetermined
        startWorkIfNeeded()
    }

    func performPermissionAction() {
        guard !stopped, !isBusy else { return }
        switch authorizationStatus {
        case .notDetermined?: checkAuthorization(requestIfUndetermined: true)
        case .denied?, .authorized?, .provisional?:
            if !service.openSettings() {
                authorizationFailure = L10n.text("Unable to open notification settings. Open System Settings > Notifications.")
            }
        default: checkAuthorization()
        }
    }

    func deliverLatest() {
        guard !stopped, hasPendingReminder else { return }
        deliveryPending = true
        checkAuthorization(requestIfUndetermined: true)
    }

    /// One owned task serializes checks, permission requests and delivery. It
    /// holds only the service or outgoing request across external awaits.
    private func startWorkIfNeeded() {
        guard !stopped, operationGeneration == nil, permissionCheckPending else { return }
        permissionCheckPending = false
        isBusy = true
        let generation = UUID()
        operationGeneration = generation
        service.setDelegate(self)
        operationTask = Task { @MainActor [weak self, service] in
            defer { self?.finishOperation(generation) }
            var status = await service.authorizationStatus()
            guard !Task.isCancelled, let request = self?.beginAuthorization(status, generation: generation) else { return }
            if request {
                do {
                    _ = try await service.requestAuthorization()
                    try Task.checkCancellation()
                    // The OS remains the source of truth, including after a prompt.
                    status = await service.authorizationStatus()
                } catch is CancellationError { return }
                catch {
                    self?.setAuthorizationFailure(generation: generation)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.completeAuthorization(status, generation: generation)
            guard status == .authorized || status == .provisional,
                  let delivery = self?.prepareDelivery(generation) else { return }
            do {
                try await service.add(delivery.request)
                try Task.checkCancellation()
                self?.recordDelivered(delivery.keys, generation: generation)
            } catch is CancellationError { return }
            catch {
                self?.setDeliveryFailure(generation: generation)
            }
        }
    }

    private func beginAuthorization(_ status: UNAuthorizationStatus, generation: UUID) -> Bool? {
        guard !stopped, operationGeneration == generation else { return nil }
        authorizationStatus = status
        authorizationFailure = nil
        let request = permissionRequestPending && status == .notDetermined
        permissionCheckPending = false
        permissionRequestPending = false
        return request
    }

    private func completeAuthorization(_ status: UNAuthorizationStatus, generation: UUID) {
        guard !stopped, operationGeneration == generation else { return }
        authorizationStatus = status
        authorizationFailure = nil
        permissionCheckPending = false
        permissionRequestPending = false
    }

    private var hasPendingReminder: Bool {
        guard let model, model.phase == .ready else { return false }
        let menu = ReminderMenuData(reports: model.reports)
        let delivered = Set(defaults.stringArray(forKey: "deliveredCalibrationReminders") ?? [])
        return !ReminderNotificationRules.pending(menu: menu, thresholdMinutes: preferences.thresholdMinutes,
                                                  deliveredKeys: delivered).isEmpty
    }

    private func prepareDelivery(_ generation: UUID) -> Delivery? {
        guard !stopped, operationGeneration == generation, deliveryPending else { return nil }
        deliveryPending = false
        // Rebuild from the latest reading after a potentially long permission wait.
        guard let model, model.phase == .ready else { return nil }
        let menu = ReminderMenuData(reports: model.reports)
        let delivered = Set(defaults.stringArray(forKey: "deliveredCalibrationReminders") ?? [])
        let rows = ReminderNotificationRules.pending(menu: menu, thresholdMinutes: preferences.thresholdMinutes,
                                                     deliveredKeys: delivered)
        guard !rows.isEmpty else { return nil }
        let content = UNMutableNotificationContent()
        content.title = rows.contains { ($0.remainingMinutes ?? 1) < 0 }
            ? L10n.text("Recalibration is overdue") : L10n.text("Recalibration is due soon")
        content.body = rows.prefix(8).map {
            L10n.text("%1$@ %2$@: %3$@", menu.monitorLabel(for: $0) ?? $0.monitorName, $0.modeName, $0.remainingText)
        }.joined(separator: "\n")
        if rows.count > 8 { content.body += "\n" + L10n.text("Additional modes: %ld", rows.count - 8) }
        content.threadIdentifier = "calibration-reminder"
        return Delivery(request: UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
                        keys: Set(rows.compactMap(ReminderNotificationRules.key)))
    }

    private func recordDelivered(_ keys: Set<String>, generation: UUID) {
        guard !stopped, operationGeneration == generation else { return }
        let delivered = Set(defaults.stringArray(forKey: "deliveredCalibrationReminders") ?? [])
        defaults.set(delivered.union(keys).sorted(), forKey: "deliveredCalibrationReminders")
        deliveryFailure = nil
    }

    private func setAuthorizationFailure(generation: UUID) {
        guard !stopped, operationGeneration == generation else { return }
        authorizationFailure = L10n.text("macOS notifications are unavailable")
    }

    private func setDeliveryFailure(generation: UUID) {
        guard !stopped, operationGeneration == generation else { return }
        deliveryFailure = L10n.text("Unable to send the notification")
    }

    private func finishOperation(_ generation: UUID) {
        guard operationGeneration == generation else { return }
        operationGeneration = nil
        operationTask = nil
        isBusy = false
        startWorkIfNeeded()
    }

    func stop() {
        stopped = true
        operationGeneration = nil
        operationTask?.cancel()
        operationTask = nil
        permissionCheckPending = false
        permissionRequestPending = false
        deliveryPending = false
        isBusy = false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list] }
}
