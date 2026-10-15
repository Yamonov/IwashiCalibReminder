import AppKit
import Observation
import ReminderSupport

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: ReminderModel
    private let preferences: ReminderPreferences
    private let notifier: ReminderNotifier
    private let menu = NSMenu()
    private let menuBuilder = MonitorMenuBuilder()
    private var statusItem: NSStatusItem?
    private var preferencesWindow: ReminderPreferencesController?
    private var menuIsOpen = false

    init(model: ReminderModel, preferences: ReminderPreferences, notifier: ReminderNotifier) {
        self.model = model; self.preferences = preferences; self.notifier = notifier
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

    private var message: String? {
        if model.isDemo { return "デモ表示" }
        switch model.phase {
        case .idle, .loading: return "情報を取得中…"
        case .blocked: return "ColorNavigator 7の画面を閉じてください"
        case .failed:
            if model.message?.contains("見つかりません") == true { return "モニターのUSB接続を確認してください" }
            return "情報を取得できませんでした"
        case .ready:
            if model.reports.isEmpty { return "対象モニターがありません" }
            return ReminderMenuData(reports: model.reports).issue ?? notifier.notice
        }
    }

    private func updateStatusImage() {
        let data = ReminderMenuData(reports: model.reports)
        let graph = ReminderGraph(menu: data, thresholdMinutes: preferences.thresholdMinutes)
        let description = data.rows.first(where: { $0.remainingMinutes != nil })?.remainingText ?? "残り時間は不明"
        let status = message
        statusItem?.button?.image = GraphImage.make(graph: graph)
        statusItem?.button?.toolTip = (["IwashiCalibReminder", description] + [status].compactMap { $0 }).joined(separator: " — ")
        statusItem?.button?.setAccessibilityLabel("IwashiCalibReminder、\(description)")
    }

    // Rebuild presentation from the cached snapshot only. This never calls refresh().
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let message {
            let item = ReadableMenuInformation.item(message)
            item.toolTip = model.message ?? message
            menu.addItem(item)
            separator()
        }
        let data = ReminderMenuData(reports: model.reports)
        menuBuilder.appendGroups(to: menu, data: data)
        separator()
        let refresh = action("情報更新", selector: #selector(refreshInformation(_:)))
        refresh.isEnabled = model.phase != .loading
        separator()
        action("環境設定…", selector: #selector(showPreferences(_:)))
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
    @objc private func quit(_ sender: Any?) { NSApplication.shared.terminate(sender) }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            let controller = ReminderPreferencesController(preferences: preferences, notifier: notifier)
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
