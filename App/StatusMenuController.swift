import AppKit
import Observation
import ReminderSupport

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: ReminderModel
    private let preferences: ReminderPreferences
    private let notifier: ReminderNotifier
    private let updater: AppUpdater
    private let menu = NSMenu()
    private let menuBuilder = MonitorMenuBuilder()
    private var statusItem: NSStatusItem?
    private var preferencesWindow: ReminderPreferencesController?
    private var menuIsOpen = false

    init(model: ReminderModel, preferences: ReminderPreferences, notifier: ReminderNotifier, updater: AppUpdater) {
        self.model = model; self.preferences = preferences; self.notifier = notifier
        self.updater = updater
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
        var result = model.isDemo ? ["デモ表示"] : model.globalMessages
        if let notice = notifier.notice { result.append(notice) }
        if let failure = updater.startupFailure { result.append(failure) }
        return result
    }

    private func updateStatusImage() {
        let graph = ReminderStatusGraph(monitors: model.monitors, thresholdMinutes: preferences.thresholdMinutes)
        let description = graph.earliest?.remainingMinutes.map(ReminderText.remaining) ?? "残り時間は不明"
        let issues = model.monitors.compactMap(\.message)
        let updateNotice = updater.updateAvailable ? ["アップデートがあります"] : []
        statusItem?.button?.image = GraphImage.make(status: graph, showsUpdateIndicator: updater.updateAvailable)
        let descriptions = ["IwashiCalibReminder", description] + messages + issues + updateNotice
        statusItem?.button?.toolTip = descriptions.joined(separator: " — ")
        statusItem?.button?.setAccessibilityLabel(descriptions.joined(separator: "、"))
    }

    // Rebuild presentation from the cached snapshot only. This never calls refresh().
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for message in messages {
            let item = ReadableMenuInformation.item(message)
            item.toolTip = model.message?.isEmpty == false ? model.message : message
            menu.addItem(item)
        }
        if !messages.isEmpty { separator() }
        let data = ReminderMenuData(monitors: model.monitors)
        menuBuilder.appendGroups(to: menu, data: data)
        separator()
        let refresh = action("情報更新", selector: #selector(refreshInformation(_:)))
        refresh.isEnabled = model.phase != .loading
        separator()
        action("環境設定…", selector: #selector(showPreferences(_:)))
        if updater.updateAvailable {
            let update = action("アップデートがあります", selector: #selector(checkForUpdates(_:)))
            update.isEnabled = updater.canCheckForUpdates
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)
                    .applying(.init(paletteColors: [.systemBlue])))
            update.image?.isTemplate = false
        }
        separator()
        action("終了", selector: #selector(quit(_:)))
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

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
    @objc private func quit(_ sender: Any?) { NSApplication.shared.terminate(sender) }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            let controller = ReminderPreferencesController(preferences: preferences, notifier: notifier, updater: updater)
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
        let prefs = NSMenuItem(title: "環境設定…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "IwashiCalibReminderを終了", action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "編集", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "編集")
        for (title, selector) in [("カット", #selector(NSText.cut(_:))),
                                       ("コピー", #selector(NSText.copy(_:))),
                                       ("ペースト", #selector(NSText.paste(_:))),
                                       ("すべてを選択", #selector(NSText.selectAll(_:)))] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: ""))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }
}
