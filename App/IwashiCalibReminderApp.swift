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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        // Demo settings are isolated and never request notification authorization.
        let defaults = isDemo ? UserDefaults(suiteName: "com.iwashiya.IwashiCalibReminder.demo")! : .standard
        let preferences = ReminderPreferences(defaults: defaults)
        let model = ReminderModel(isDemo: isDemo, diagnostics: isDemo ? nil : .shared)
        let notifier = ReminderNotifier(preferences: preferences, model: model, defaults: defaults, isDemo: isDemo)
        let updater = AppUpdater(isDemo: isDemo)
        let controller = StatusMenuController(model: model, preferences: preferences, notifier: notifier, updater: updater)
        self.model = model
        self.controller = controller
        model.didRead = { [weak notifier] _ in
            Task { @MainActor in await notifier?.deliverLatest() }
        }
        controller.install()
        if !isDemo {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                center.addObserver(self, selector: #selector(workspaceDidWake(_:)), name: name, object: nil)
            }
        }
        model.start()
        updater.start()
        if ProcessInfo.processInfo.arguments.contains("--preferences") { controller.showPreferences(nil) }
    }

    @objc nonisolated private func workspaceDidWake(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.model?.refreshAfterWake() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        model?.stop()
    }
}
