import AppKit

@MainActor
enum CompactMenuViews {
    static let font = NSFont.menuFont(ofSize: 13)

    static func valueColumn(_ entries: [ModeDetailEntry]) -> CGFloat {
        ceil(entries.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
    }

    static func value(_ entry: ModeDetailEntry, column: CGFloat, dimmed: Bool = false,
                      labelAlignment: NSTextAlignment = .right, valueAlignment: NSTextAlignment = .left,
                      trailingInset: CGFloat = 14) -> NSMenuItem {
        let item = NSMenuItem(title: entry.label + "　" + entry.value, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = MenuValueView(entry: entry, column: column, dimmed: dimmed,
            labelAlignment: labelAlignment, valueAlignment: valueAlignment, trailingInset: trailingInset)
        return item
    }

    static func checkmark(_ title: String, isOn: Bool?, dimmed: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.state = isOn.map { $0 ? .on : .off } ?? .mixed
        let mark = isOn.map { $0 ? "✓" : "" } ?? "—"
        let stateText = isOn.map(ModeDetailText.onOff) ?? L10n.text("Not recorded")
        let view = MenuValueView(entry: ModeDetailEntry(mark, title), column: 14, dimmed: dimmed,
            labelAlignment: .center, valueAlignment: .left, trailingInset: 14, spacing: 6)
        view.setAccessibilityLabel(title)
        view.setAccessibilityValue(stateText)
        item.view = view
        if isOn == nil { item.toolTip = stateText }
        return item
    }

    static func message(_ text: String, maximumLines: Int = 3) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = text
        item.view = MenuMessageView(text: text, maximumLines: maximumLines)
        return item
    }

    static func modeRow(_ row: ReminderMenuRow, dimmed: Bool, showsSubmenu: Bool) -> NSView {
        ModeMenuRowView(row: row, dimmed: dimmed, showsSubmenu: showsSubmenu)
    }

    static func highlight(_ item: NSMenuItem, selected: Bool) {
        (item.view as? ModeMenuRowView)?.isSelected = selected
    }

    static func card(_ presentation: ModeMenuPresentation) -> NSMenuItem {
        let item = NSMenuItem(title: "[\(presentation.badge)]" + presentation.name, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = MenuCardView(title: presentation.name, icon: badge(presentation.badge), iconWidth: 32,
            rows: presentation.cardLines.map { ($0, nil) }, accessibilityPrefix: presentation.badge)
        return item
    }

    static func monitorCard(title: String, usage: String?, schedule: String?, dimmed: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        var rows: [(String, String?)] = []
        if let usage { rows.append((L10n.text("Total usage"), usage)) }
        if let schedule { rows.append((schedule, nil)) }
        item.view = MenuCardView(title: title,
            icon: NSImage(systemSymbolName: "display", accessibilityDescription: nil) ?? NSImage(),
            iconWidth: 16, rows: rows, titleWeight: .bold, dimmed: dimmed, usesAccentTint: true)
        return item
    }

    static func gamut(_ rows: [ModeDetailEntry], column: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.text("Gamut x y"), action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = GamutMenuView(rows: rows, column: column)
        return item
    }

    static func badge(_ text: String, dimmed: Bool = false, selected: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 15), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            let foreground: NSColor
            if text == "ADV" {
                (dimmed ? NSColor.disabledControlTextColor : NSColor.controlAccentColor).setFill()
                path.fill()
                foreground = .white
            } else {
                foreground = dimmed ? .disabledControlTextColor : selected ? .selectedMenuItemTextColor : .labelColor
                foreground.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                                                            .foregroundColor: foreground]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
                                   withAttributes: attributes)
            return true
        }
    }
}

@MainActor
private final class MenuValueView: NSView {
    private let label: NSTextField
    private let value: NSTextField
    private let column: CGFloat
    private let naturalWidth: CGFloat
    private let dimmed: Bool
    private let trailingInset: CGFloat
    private let spacing: CGFloat
    init(entry: ModeDetailEntry, column: CGFloat, dimmed: Bool,
         labelAlignment: NSTextAlignment, valueAlignment: NSTextAlignment, trailingInset: CGFloat,
         spacing: CGFloat = 14) {
        label = NSTextField(labelWithString: entry.label)
        value = NSTextField(labelWithString: entry.value)
        self.column = column
        self.dimmed = dimmed
        self.trailingInset = trailingInset
        self.spacing = spacing
        label.font = CompactMenuViews.font; value.font = CompactMenuViews.font
        label.alignment = labelAlignment; value.alignment = valueAlignment
        naturalWidth = ceil(14 + column + spacing + trailingInset + value.fittingSize.width)
        super.init(frame: NSRect(x: 0, y: 0, width: naturalWidth, height: 22))
        autoresizingMask = [.width]
        addSubview(label); addSubview(value)
        updateColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(entry.label + " " + entry.value)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: 22) }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 14, y: 2, width: column, height: 18)
        value.frame = NSRect(x: 14 + column + spacing, y: 2,
            width: max(0, bounds.width - column - 14 - spacing - trailingInset), height: 18)
    }
    private func updateColors() {
        label.textColor = dimmed ? .disabledControlTextColor : .labelColor
        value.textColor = label.textColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
}

@MainActor
private final class ModeMenuRowView: NSView {
    private let icon: NSImageView
    private let name: NSTextField
    private let time: NSTextField
    private let arrow: NSImageView
    private let dimmed: Bool
    private let naturalWidth: CGFloat
    private let timeWidth: CGFloat
    private let badgeText: String
    var isSelected = false { didSet { updateColors(); needsDisplay = true } }

    init(row: ReminderMenuRow, dimmed: Bool, showsSubmenu: Bool) {
        icon = NSImageView(image: CompactMenuViews.badge(row.badge, dimmed: dimmed))
        name = NSTextField(labelWithString: row.modeName)
        time = NSTextField(labelWithString: row.remainingMinutes == nil ? "" : row.remainingText)
        arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        self.dimmed = dimmed
        badgeText = row.badge
        name.font = CompactMenuViews.font; time.font = CompactMenuViews.font
        time.alignment = .right
        timeWidth = ceil(time.fittingSize.width)
        naturalWidth = ceil(52 + name.fittingSize.width + (timeWidth > 0 ? 12 + timeWidth : 0) + 34)
        super.init(frame: NSRect(x: 0, y: 0, width: naturalWidth, height: 24))
        autoresizingMask = [.width]
        [icon, name, time, arrow].forEach(addSubview)
        arrow.isHidden = !showsSubmenu
        updateColors()
        // The NSMenuItem owns selection, submenu tracking and accessibility.
        // This view only draws the row and must not intercept those interactions.
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: 24) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 14, y: 4, width: 32, height: 15)
        let timeStart = bounds.width - 34 - timeWidth
        name.frame = NSRect(x: 52, y: 3, width: max(0, (timeWidth > 0 ? timeStart - 12 : bounds.width - 34) - 52), height: 18)
        time.frame = NSRect(x: timeStart, y: 3, width: timeWidth, height: 18)
        arrow.frame = NSRect(x: bounds.width - 22, y: 7, width: 8, height: 10)
    }
    override func draw(_ dirtyRect: NSRect) {
        if isSelected && !dimmed {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }
    private func updateColors() {
        let color: NSColor = dimmed ? .disabledControlTextColor : isSelected ? .selectedMenuItemTextColor : .labelColor
        name.textColor = color; time.textColor = color; arrow.contentTintColor = color
        icon.image = CompactMenuViews.badge(badgeText, dimmed: dimmed, selected: isSelected)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
}

@MainActor
private final class MenuMessageView: NSView {
    private let label: NSTextField
    private let size: NSSize
    init(text: String, maximumLines: Int) {
        label = NSTextField(wrappingLabelWithString: text)
        label.font = CompactMenuViews.font
        label.textColor = .labelColor
        label.maximumNumberOfLines = maximumLines
        label.lineBreakMode = .byTruncatingTail
        let width = min(440, max(180, ceil((text as NSString).size(withAttributes: [.font: CompactMenuViews.font]).width)))
        let measured = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: CompactMenuViews.font])
        size = NSSize(width: width + 28, height: min(CGFloat(maximumLines) * 19, max(19, ceil(measured.height))) + 6)
        super.init(frame: NSRect(origin: .zero, size: size))
        autoresizingMask = [.width]
        addSubview(label)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { size }
    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 14, dy: 3) }
}

@MainActor
private final class MenuCardView: NSView {
    private let icon: NSImageView
    private let title: NSTextField
    private let rows: [(NSTextField, NSTextField?)]
    private let iconWidth: CGFloat
    private let usesAccentTint: Bool
    private let size: NSSize
    override var isFlipped: Bool { true }
    init(title text: String, icon image: NSImage, iconWidth: CGFloat, rows texts: [(String, String?)],
         titleWeight: NSFont.Weight = .semibold, dimmed: Bool = false, usesAccentTint: Bool = false,
         accessibilityPrefix: String = "") {
        icon = NSImageView(image: image)
        self.iconWidth = iconWidth
        self.usesAccentTint = usesAccentTint
        title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 13, weight: titleWeight)
        func field(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = dimmed ? .disabledControlTextColor : .secondaryLabelColor
            return field
        }
        rows = texts.map { left, right in
            let value = right.map(field)
            value?.alignment = .right
            return (field(left), value)
        }
        let rowWidth = rows.map { $0.0.fittingSize.width + ($0.1.map { $0.fittingSize.width + 30 } ?? 0) }.max() ?? 0
        let width = max(300, title.fittingSize.width + iconWidth + 48, rowWidth + 36)
        size = NSSize(width: ceil(width), height: 42 + CGFloat(rows.count) * 19)
        super.init(frame: NSRect(origin: .zero, size: size))
        autoresizingMask = [.width]
        addSubview(icon); addSubview(title)
        for (label, value) in rows { addSubview(label); if let value { addSubview(value) } }
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        let lines = texts.map { $0.0 + ($0.1.map { " " + $0 } ?? "") }
        setAccessibilityLabel(([accessibilityPrefix + " " + text] + lines).joined(separator: L10n.text(", ")))
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { size }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 16, y: 13, width: iconWidth, height: 15)
        let titleX = 24 + iconWidth
        title.frame = NSRect(x: titleX, y: 11, width: max(0, bounds.width - titleX - 16), height: 20)
        for (index, row) in rows.enumerated() {
            let y = 33 + CGFloat(index) * 19
            let width = row.1?.fittingSize.width ?? 0
            row.0.frame = NSRect(x: 16, y: y,
                width: max(0, bounds.width - (row.1 == nil ? 32 : 62 + width)), height: 19)
            row.1?.frame = NSRect(x: bounds.width - 34 - width, y: y, width: width, height: 19)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 4), xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        path.fill()
        if usesAccentTint {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
private final class GamutMenuView: NSView {
    private let labels: [NSTextField]
    private let column: CGFloat
    private let size: NSSize
    override var isFlipped: Bool { true }
    init(rows: [ModeDetailEntry], column: CGFloat) {
        self.column = column
        let cells = [[L10n.text("Gamut"), "x", "y"]] + rows.map { [$0.label] + $0.value.components(separatedBy: "\t") }
        labels = cells.flatMap { $0 }.map {
            let field = NSTextField(labelWithString: $0)
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            return field
        }
        size = NSSize(width: column + 180, height: CGFloat(cells.count) * 22)
        super.init(frame: NSRect(origin: .zero, size: size))
        for (index, label) in labels.enumerated() { label.alignment = index % 3 == 0 ? .right : .left }
        autoresizingMask = [.width]; labels.forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel(cells.map { $0.joined(separator: " ") }.joined(separator: L10n.text(", ")))
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { size }
    override func layout() {
        super.layout()
        for (index, label) in labels.enumerated() {
            let c = index % 3, r = index / 3
            label.frame = NSRect(x: c == 0 ? 14 : 28 + column + CGFloat(c - 1) * 70,
                y: CGFloat(r) * 22 + 2, width: c == 0 ? column : 68, height: 18)
        }
    }
}
