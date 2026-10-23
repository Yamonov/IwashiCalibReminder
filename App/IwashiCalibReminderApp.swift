import AppKit
import EIZOHID
import ReminderSupport

@main
@MainActor
enum IwashiCalibReminderApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = ReminderAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class ReminderAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusMenuController?
    private var model: ReminderModel?
    private var notifier: ReminderNotifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchReason = ApplicationLaunchReason.detect(NSAppleEventManager.shared().currentAppleEvent)
        let defaults = UserDefaults.standard
        let preferences = ReminderPreferences(defaults: defaults)
        let model = ReminderModel(diagnostics: .shared)
        let notifier = ReminderNotifier(preferences: preferences, model: model, defaults: defaults)
        let updater = AppUpdater()
        let loginItem = LoginItemController()
        let controller = StatusMenuController(model: model, preferences: preferences, notifier: notifier,
            updater: updater, loginItem: loginItem)
        self.model = model
        self.notifier = notifier
        self.controller = controller
        model.didRead = { [weak notifier] _ in notifier?.deliverLatest() }
        model.didFinishInitialWait = { [weak updater, weak notifier] in
            notifier?.checkAuthorization(requestIfUndetermined: true)
            updater?.start()
        }
        controller.install()
        notifier.checkAuthorization()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(self, selector: #selector(workspacePowerChanged(_:)), name: name, object: nil)
        }
        model.start(launchReason: launchReason)
    }

    @objc nonisolated private func workspacePowerChanged(_ notification: Notification) {
        let event: ReminderModel.PowerEvent
        switch notification.name {
        case NSWorkspace.willSleepNotification: event = .systemWillSleep
        case NSWorkspace.screensDidSleepNotification: event = .displaysDidSleep
        case NSWorkspace.didWakeNotification: event = .systemDidWake
        case NSWorkspace.screensDidWakeNotification: event = .displaysDidWake
        default: return
        }
        Task { @MainActor [weak self] in self?.model?.handlePowerEvent(event) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        model?.stop()
        notifier?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        notifier?.checkAuthorization()
    }
}
