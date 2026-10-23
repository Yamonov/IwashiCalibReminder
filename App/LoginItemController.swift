import AppKit
import Observation
import ReminderSupport
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
private struct MainAppLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The system registration is the source of truth; there is no duplicate preference.
@Observable @MainActor
final class LoginItemController {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var notice: String?
    @ObservationIgnored private let service: any LoginItemService

    init(service: (any LoginItemService)? = nil) {
        self.service = service ?? MainAppLoginItemService()
        refresh()
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
        notice = requiresApproval ? L10n.text("Allow launch at login in System Settings.") : nil
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        if enabled, requiresApproval { service.openSettings(); return }
        guard enabled != isEnabled || (!enabled && requiresApproval) else { return }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            refresh()
        } catch {
            refresh()
            if !requiresApproval {
                notice = L10n.text("Unable to change launch at login: %@", error.localizedDescription)
            }
        }
    }

    func openSettings() { service.openSettings() }
}
