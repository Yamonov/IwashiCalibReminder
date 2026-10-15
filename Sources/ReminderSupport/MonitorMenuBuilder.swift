import AppKit
import EIZOHID

/// Builds only from an immutable reading. No device, database, or notification work
/// is performed when either the root menu or a detail submenu is opened.
@MainActor
public final class MonitorMenuBuilder {
    private var savedDataMenus = SavedDataMenuBuilder()
    private var detailSources: [DeferredMenuSource] = []
    public init() {}

    public func appendGroups(to menu: NSMenu, data: ReminderMenuData) {
        savedDataMenus = SavedDataMenuBuilder()
        detailSources = []
        menu.minimumWidth = 0
        let font = NSFont.menuFont(ofSize: 13)
        let modeWidth = data.rows.map { ($0.modeName as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let timeWidth = data.rows.map { ($0.remainingText as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: ceil(modeWidth) + 14),
                              NSTextTab(textAlignment: .right, location: ceil(modeWidth) + 14 + 30 + 14 + ceil(timeWidth) + 4)]
        paragraph.defaultTabInterval = 1
        for group in data.groups {
            menu.addItem(header(group.title, symbol: "display"))
            if group.rows.isEmpty {
                let item = ReadableMenuInformation.item("モード情報を取得できません")
                item.indentationLevel = 1
                menu.addItem(item)
            }
            for row in group.rows {
                let title = "\(row.modeName) [\(row.badge)] \(row.remainingText)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
                let text = NSMutableAttributedString(string: row.modeName + "\t", attributes: attributes)
                let attachment = NSTextAttachment()
                attachment.image = badge(row.badge)
                attachment.bounds = NSRect(x: 0, y: -2, width: 30, height: 13)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: "\t" + row.remainingText, attributes: attributes))
                item.attributedTitle = text
                item.toolTip = "\(group.report.monitor.model) / S/N \(row.serialNumber) / モード \(row.modeNumber)"
                if let mode = group.report.calibrationHistory.colorModes.first(where: { $0.modeNumber == row.modeNumber }) {
                    item.submenu = deferredDetailMenu(report: group.report, mode: mode)
                }
                menu.addItem(item)
            }
        }
    }

    /// Call after menu tracking ends. The reading belongs to the model; none of
    /// the menu views or expanded JSON branches need to survive between visits.
    public func clear(_ menu: NSMenu) {
        menu.removeAllItems()
        detailSources = []
        savedDataMenus = SavedDataMenuBuilder()
    }

    private func deferredDetailMenu(report: MonitorUsageReport, mode: CNColorModeHistory) -> NSMenu {
        deferredMenu { [weak self] menu in
            self?.populate(menu, with: ModeDetailPresentation(report: report, mode: mode))
        }
    }

    private func deferredMenu(populate: @escaping (NSMenu) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let source = DeferredMenuSource(populate: populate)
        detailSources.append(source)
        menu.delegate = source
        menu.addItem(ReadableMenuInformation.item("取得済みの詳細を表示"))
        return menu
    }

    private func populate(_ menu: NSMenu, with detail: ModeDetailPresentation) {
        for section in detail.sections {
            if section.inline {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(header(section.title, symbol: nil))
                section.entries.forEach { menu.addItem(ReadableMenuInformation.item($0.title)) }
            } else {
                let item = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
                item.submenu = deferredMenu { submenu in
                    section.entries.forEach { submenu.addItem(ReadableMenuInformation.item($0.title)) }
                }
                menu.addItem(item)
            }
        }
        if !detail.rawRecords.isEmpty {
            menu.addItem(.separator())
            let raw = NSMenuItem(title: "保存データの全項目", action: nil, keyEquivalent: "")
            raw.submenu = savedDataMenus.menu(entries: detail.rawRecords)
            menu.addItem(raw)
        }
    }

    private func header(_ title: String, symbol: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = MonitorSectionHeaderView(title: title, symbol: symbol)
        return item
    }

    private func badge(_ title: String) -> NSImage {
        NSImage(size: NSSize(width: 30, height: 13), flipped: false) { rect in
            NSColor.secondaryLabelColor.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            border.lineWidth = 1
            border.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .medium),
                                                           .foregroundColor: NSColor.labelColor]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
                                     withAttributes: attributes)
            return true
        }
    }
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
