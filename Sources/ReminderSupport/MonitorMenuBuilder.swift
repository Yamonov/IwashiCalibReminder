import AppKit
import EIZOHID

public enum ICCProfileAction: Equatable, Sendable { case copyPath, showInFinder }

/// Presentation only: opening a menu never queries the monitor or CN database.
@MainActor
public final class MonitorMenuBuilder {
    private var detailSources: [DeferredMenuSource] = []
    private var profileTargets: [ProfileMenuTarget] = []
    private var modeItems: [NSMenuItem] = []
    private let profileAction: @MainActor (ICCProfileAction, URL) -> Void

    public init(profileAction: (@MainActor (ICCProfileAction, URL) -> Void)? = nil) {
        self.profileAction = profileAction ?? { action, url in
            switch action {
            case .copyPath:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            case .showInFinder:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    public func appendMessages(_ messages: [String], to menu: NSMenu, detail: String? = nil) {
        guard !messages.isEmpty else { return }
        let item = CompactMenuViews.message(messages.joined(separator: "\n"))
        item.toolTip = detail?.isEmpty == false ? detail : messages.joined(separator: "\n")
        menu.addItem(item)
    }

    public func appendGroups(to menu: NSMenu, data: ReminderMenuData) {
        detailSources = []
        profileTargets = []
        modeItems = []
        menu.minimumWidth = 0
        for (index, group) in data.groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(CompactMenuViews.monitorCard(title: group.title,
                usage: group.information.map { ModeMenuPresentation.approximateHours($0.usageMinutes) },
                schedule: group.information == nil ? nil : scheduleDescription(group), dimmed: group.isShowingPrevious))
            let showsHistory = (group.isShowingPrevious && group.lastSuccessAt != nil)
                || (group.isStale && group.rows.isEmpty && group.lastSuccessAt == nil)
            if let message = group.message {
                let item = CompactMenuViews.message(message, maximumLines: showsHistory ? 2 : 3)
                item.toolTip = group.detail ?? message
                menu.addItem(item)
            }
            if group.isShowingPrevious, let date = group.lastSuccessAt {
                menu.addItem(ReadableMenuInformation.item(L10n.text("Last successful read: %@ (previous data)", ModeMenuPresentation.dateText(date))))
            } else if group.isStale, group.rows.isEmpty, group.lastSuccessAt == nil {
                menu.addItem(ReadableMenuInformation.item(L10n.text("No previous reading")))
            }
            if let information = group.information {
                let common = NSMenuItem(title: L10n.text("Common settings"), action: nil, keyEquivalent: "")
                let settings = information.commonSettings
                let dimmed = group.isShowingPrevious
                common.submenu = deferredMenu { menu in
                    let entries: [(String, Bool?)] = [
                        (L10n.text("Check monitor resolution at startup"), settings?.checkResolution),
                        (L10n.text("Do not apply ICC profiles"), settings?.appliesICCProfile.map { !$0 }),
                        (L10n.text("Monitor display and input signal settings"), settings?.checkSignalInfoWarning),
                        (L10n.text("Monitor video card gamma and keep it linear"), settings?.checkVideoCardGammaChangeToMakeItLinear)
                    ]
                    for (label, value) in entries {
                        menu.addItem(CompactMenuViews.checkmark(label, isOn: value, dimmed: dimmed))
                    }
                }
                menu.addItem(common)
            }
            if !group.rows.isEmpty { menu.addItem(.separator()) }
            for row in group.rows {
                let item = NSMenuItem(title: "[\(row.badge)]" + row.modeName, action: nil, keyEquivalent: "")
                item.representedObject = row.id
                item.setAccessibilityLabel("[\(row.badge)]" + row.modeName + (row.remainingMinutes == nil ? "" : " " + row.remainingText))
                item.isEnabled = !group.isShowingPrevious
                if !group.isShowingPrevious, let report = group.report,
                   let mode = report.calibrationHistory.colorModes.first(where: { $0.modeNumber == row.modeNumber }) {
                    item.submenu = deferredMenu { [weak self] menu in
                        self?.populate(menu, with: ModeMenuPresentation(report: report, mode: mode))
                    }
                }
                item.view = CompactMenuViews.modeRow(row, dimmed: group.isShowingPrevious, showsSubmenu: item.hasSubmenu)
                modeItems.append(item)
                menu.addItem(item)
            }
        }
    }

    public func highlight(_ item: NSMenuItem?) {
        modeItems.forEach { CompactMenuViews.highlight($0, selected: $0 === item) }
    }

    private func scheduleDescription(_ group: ReminderMonitorGroup) -> String {
        guard let policy = group.information?.policy else { return L10n.text("Calibration interval is unknown") }
        if policy.type == "None" { return L10n.text("No scheduled calibration") }
        if policy.scheduleType == "EveryUsageTime", let hours = policy.intervalHours {
            return L10n.text("Calibrate every %ld h", hours)
        }
        if let next = group.rows.compactMap({ $0.nextCalibrationDate.flatMap(CNDate.iso) }).min() {
            return L10n.text("Calibrate on %@", ModeMenuPresentation.dateText(next))
        }
        return L10n.text("Next calibration date is unknown")
    }

    public func clear(_ menu: NSMenu) {
        menu.removeAllItems()
        detailSources = []
        profileTargets = []
        modeItems = []
    }

    private func deferredMenu(populate: @escaping (NSMenu) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let source = DeferredMenuSource(populate: populate)
        detailSources.append(source)
        menu.delegate = source
        menu.addItem(ReadableMenuInformation.item(L10n.text("Show acquired information")))
        return menu
    }

    private func populate(_ menu: NSMenu, with detail: ModeMenuPresentation) {
        menu.addItem(CompactMenuViews.card(detail))
        menu.addItem(.separator())
        let detailColumn = CompactMenuViews.valueColumn(detail.entries)
        for entry in detail.entries {
            if entry.label == L10n.text("Gamut"), !detail.gamutCoordinates.isEmpty {
                menu.addItem(CompactMenuViews.gamut(detail.gamutCoordinates, column: detailColumn))
            } else { menu.addItem(CompactMenuViews.value(entry, column: detailColumn)) }
        }
        menu.addItem(.separator())
        let profile = NSMenuItem(title: L10n.text("ICC profile"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let url = detail.profilePath.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        for (label, action) in [(L10n.text("Copy path"), ICCProfileAction.copyPath), (L10n.text("Show in Finder"), .showInFinder)] {
            let item = NSMenuItem(title: label, action: #selector(ProfileMenuTarget.runProfileAction(_:)), keyEquivalent: "")
            if let url {
                let target = ProfileMenuTarget(action: action, url: url, handler: profileAction)
                profileTargets.append(target)
                item.target = target
                item.toolTip = url.path
            } else { item.isEnabled = false }
            submenu.addItem(item)
        }
        profile.submenu = submenu
        menu.addItem(profile)
        if let url {
            menu.addItem(ReadableMenuInformation.item(url.lastPathComponent, secondary: true, maximumWidth: 520))
        }
        if detail.usesSpecifiedProfile {
            menu.addItem(ReadableMenuInformation.item(L10n.text("Use the specified ICC profile")))
        } else {
            let profileColumn = CompactMenuViews.valueColumn(detail.profileEntries)
            detail.profileEntries.forEach { menu.addItem(CompactMenuViews.value($0, column: profileColumn)) }
        }
    }

}

@MainActor
private final class ProfileMenuTarget: NSObject {
    let action: ICCProfileAction
    let url: URL
    let handler: @MainActor (ICCProfileAction, URL) -> Void
    init(action: ICCProfileAction, url: URL, handler: @escaping @MainActor (ICCProfileAction, URL) -> Void) {
        self.action = action; self.url = url; self.handler = handler
    }
    @objc func runProfileAction(_ sender: Any?) { handler(action, url) }
}

@MainActor
private final class DeferredMenuSource: NSObject, NSMenuDelegate {
    private var populate: ((NSMenu) -> Void)?

    init(populate: @escaping (NSMenu) -> Void) { self.populate = populate }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let populate else { return }
        self.populate = nil
        menu.removeAllItems()
        populate(menu)
    }
}
