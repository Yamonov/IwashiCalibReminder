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
    private struct ProfileWindow {
        let window: NSWindow
        let target: CNRegisteredMonitor
    }

    private var profileWindows: [CGDirectDisplayID: ProfileWindow] = [:]
    private var profileMonitors: [CNRegisteredMonitor: String] = [:]

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
        model.didApplySnapshot = { [weak self] in self?.updateProfileMonitors($0) }
        model.didEnumerateUSB = { [weak self] in self?.removeDisconnectedProfileMonitors($0) }
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

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if model != nil { updateProfileWindows() }
    }

    private func updateProfileMonitors(_ snapshot: MonitorRefreshResult) {
        var monitors = profileMonitors
        if let registered = snapshot.registeredMonitors {
            let allowed = Set(registered)
            monitors = monitors.filter { allowed.contains($0.key) }
        }
        if let registryIDs = snapshot.discovery?.connectedRegistryIDs {
            let connected = Set(registryIDs)
            monitors = monitors.filter { connected.contains($0.value) }
        }
        if snapshot.globalFailures.contains(where: { $0.kind == .noRegisteredMonitors }) { monitors.removeAll() }
        for report in snapshot.reports {
            let reading = report.monitor
            let monitor = CNRegisteredMonitor(model: reading.model, serialNumber: reading.serialNumber)
            if let registryID = reading.registryID, reading.supportsSelectedMode == true || reading.selectedModeNumber != nil {
                monitors[monitor] = registryID
            } else if reading.supportsSelectedMode == false {
                monitors.removeValue(forKey: monitor)
            }
        }
        setProfileMonitors(monitors)
    }

    private func removeDisconnectedProfileMonitors(_ registryIDs: [String]) {
        let connected = Set(registryIDs)
        setProfileMonitors(profileMonitors.filter { connected.contains($0.value) })
    }

    private func setProfileMonitors(_ monitors: [CNRegisteredMonitor: String]) {
        guard monitors != profileMonitors else { return }
        profileMonitors = monitors
        updateProfileWindows()
    }

    private func updateProfileWindows() {
        let center = NotificationCenter.default
        var windows: [CGDirectDisplayID: ProfileWindow] = [:]
        let monitorsBySerial = Dictionary(grouping: profileMonitors.keys) { UInt32($0.serialNumber) }
        var screensBySerial: [UInt32: [(CGDirectDisplayID, NSScreen)]] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = number.uint32Value
            // EIZO's EDID manufacturer code is ENC (0x15C3), distinct from its USB vendor ID.
            guard CGDisplayVendorNumber(displayID) == 0x15C3 else { continue }
            let serial = CGDisplaySerialNumber(displayID)
            guard serial != 0, monitorsBySerial[serial]?.count == 1 else { continue }
            screensBySerial[serial, default: []].append((displayID, screen))
        }
        for (serial, matches) in screensBySerial where matches.count == 1 {
            guard let (displayID, screen) = matches.first, let monitor = monitorsBySerial[serial]?.first else { continue }
            let frame = NSRect(origin: CGPoint(x: screen.frame.midX, y: screen.frame.midY),
                               size: NSSize(width: 1, height: 1))
            if let existing = profileWindows[displayID], existing.target == monitor, existing.window.frame == frame {
                windows[displayID] = existing
                continue
            }
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered,
                                  defer: false, screen: screen)
            window.setFrame(frame, display: false)
            window.displaysWhenScreenProfileChanges = true
            // Keep a screen-bound window without adding it to the window order.
            center.addObserver(self, selector: #selector(displayProfileChanged(_:)),
                name: NSWindow.didChangeScreenProfileNotification, object: window)
            windows[displayID] = ProfileWindow(window: window, target: monitor)
        }
        for (id, entry) in profileWindows where windows[id]?.window !== entry.window {
            center.removeObserver(self, name: NSWindow.didChangeScreenProfileNotification, object: entry.window)
        }
        if Set(profileWindows.keys) != Set(windows.keys) {
            DiagnosticLog.shared.record(DiagnosticEvent("display_profile.monitors",
                fields: ["displayIDs": windows.keys.sorted().map(String.init).joined(separator: ",")], level: .notice))
        }
        profileWindows = windows
    }

    @objc private func displayProfileChanged(_ notification: Notification) {
        DiagnosticLog.shared.record(DiagnosticEvent("display_profile.received",
            fields: ["notification": notification.name.rawValue], level: .notice))
        guard let window = notification.object as? NSWindow,
              let target = profileWindows.values.first(where: { $0.window === window })?.target else { return }
        model?.handleDisplayProfileChange(target: target)
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
        NotificationCenter.default.removeObserver(self)
        profileWindows.removeAll()
        profileMonitors.removeAll()
        model?.stop()
        notifier?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        notifier?.checkAuthorization()
    }
}
