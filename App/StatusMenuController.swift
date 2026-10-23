import AppKit
import Observation
import ReminderSupport

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: ReminderModel
    private let preferences: ReminderPreferences
    private let notifier: ReminderNotifier
    private let updater: AppUpdater
    private let loginItem: LoginItemController
    private let menu = NSMenu()
    private let menuBuilder = MonitorMenuBuilder()
    private var statusItem: NSStatusItem?
    private var preferencesWindow: ReminderPreferencesController?
    private var menuIsOpen = false
    private var displayTask: Task<Void, Never>?

    deinit { displayTask?.cancel() }

    init(model: ReminderModel, preferences: ReminderPreferences, notifier: ReminderNotifier, updater: AppUpdater,
         loginItem: LoginItemController) {
        self.model = model; self.preferences = preferences; self.notifier = notifier
        self.updater = updater
        self.loginItem = loginItem
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "IwashiCalibReminder"
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        installApplicationMenu()
        observe()
    }

    private func observe() {
        withObservationTracking {
            updateStatusImage()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private var messages: [String] {
        var result = model.globalMessages
        if let notice = notifier.notice { result.append(notice) }
        if let failure = updater.startupFailure { result.append(failure) }
        return result
    }

    private func updateStatusImage() {
        let graph = ReminderStatusGraph(monitors: model.monitors, thresholdMinutes: preferences.thresholdMinutes)
        let description = graph.earliest?.remainingMinutes.map(ReminderText.remaining) ?? L10n.text("Remaining time is unknown")
        let issues = model.monitors.compactMap(\.message)
        let updateNotice = updater.updateAvailable ? [L10n.text("An app update is available")] : []
        statusItem?.button?.image = GraphImage.make(status: graph, showsUpdateIndicator: updater.updateAvailable)
        let descriptions = ["IwashiCalibReminder", description] + messages + issues + updateNotice
        statusItem?.button?.toolTip = descriptions.joined(separator: " — ")
        statusItem?.button?.setAccessibilityLabel(descriptions.joined(separator: L10n.text(", ")))
        scheduleDisplayChange(graph.nextDisplayChange)
    }

    private func scheduleDisplayChange(_ date: Date?) {
        displayTask?.cancel()
        displayTask = nil
        guard !model.isSuspended, let date else { return }
        let delay = max(1, date.timeIntervalSinceNow)
        displayTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(1)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            displayTask = nil
            updateStatusImage()
        }
    }

    // Rebuild presentation from the cached snapshot only. This never calls refresh().
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateStatusImage()
        menu.removeAllItems()
        menuBuilder.appendMessages(messages, to: menu, detail: model.message)
        let data = ReminderMenuData(monitors: model.monitors)
        menuBuilder.appendGroups(to: menu, data: data)
        separator()
        let refresh = action(L10n.text("Refresh information"), selector: #selector(refreshInformation(_:)))
        refresh.isEnabled = model.canRefresh
        separator()
        action(L10n.text("About IwashiCalibReminder..."), selector: #selector(showAbout(_:)))
        let update = action(updater.updateAvailable ? L10n.text("An app update is available") : L10n.text("Check for updates..."),
                            selector: #selector(checkForUpdates(_:)))
        update.isEnabled = updater.canCheckForUpdates
        if updater.updateAvailable {
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)
                    .applying(.init(paletteColors: [.systemBlue])))
            update.image?.isTemplate = false
        }
        separator()
        action(L10n.text("Settings"), selector: #selector(showPreferences(_:)))
        separator()
        action(L10n.text("Quit"), selector: #selector(quit(_:)))
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { menuBuilder.highlight(item) }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Let AppKit dispatch the selected action before releasing its menu item.
        Task { @MainActor [weak self] in
            guard let self, !menuIsOpen else { return }
            menuBuilder.clear(menu)
        }
    }

    private func separator() {
        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
    }

    @discardableResult
    private func action(_ title: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func refreshInformation(_ sender: Any?) { model.refresh() }
    @objc private func checkForUpdates(_ sender: Any?) { updater.checkForUpdates() }
    @objc private func showAbout(_ sender: Any?) {
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(sender)
    }
    @objc private func quit(_ sender: Any?) { NSApplication.shared.terminate(sender) }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            let controller = ReminderPreferencesController(preferences: preferences, notifier: notifier,
                updater: updater, loginItem: loginItem)
            controller.onClose = { [weak self] in self?.preferencesWindow = nil }
            preferencesWindow = controller
        }
        preferencesWindow?.showWindow(nil)
        NSApplication.shared.activate()
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "IwashiCalibReminder")
        let prefs = NSMenuItem(title: L10n.text("Settings"), action: #selector(showPreferences(_:)), keyEquivalent: "")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("Quit IwashiCalibReminder"), action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: L10n.text("Edit"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: L10n.text("Edit"))
        for (title, selector) in [(L10n.text("Cut"), #selector(NSText.cut(_:))),
                                       (L10n.text("Copy"), #selector(NSText.copy(_:))),
                                       (L10n.text("Paste"), #selector(NSText.paste(_:))),
                                       (L10n.text("Select All"), #selector(NSText.selectAll(_:)))] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: ""))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }
}
