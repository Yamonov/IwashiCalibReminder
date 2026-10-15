import AppKit

/// A disabled native title is dimmed by AppKit. A non-interactive custom view owns
/// its drawing and keeps the normal label color in light, dark, and high contrast.
@MainActor
public enum ReadableMenuInformation {
    public static func item(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = title
        item.view = InformationRowView(title: title)
        return item
    }
}

@MainActor
private final class InformationRowView: NSView {
    private let label: NSTextField
    private let preferredWidth: CGFloat
    init(title: String) {
        let field = NSTextField(labelWithString: title)
        field.font = NSFont.menuFont(ofSize: 13)
        field.textColor = .labelColor
        field.lineBreakMode = .byClipping
        field.isSelectable = false
        label = field
        preferredWidth = ceil(field.fittingSize.width) + 28
        super.init(frame: NSRect(x: 0, y: 0, width: preferredWidth, height: 22))
        autoresizingMask = [.width]
        addSubview(field)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 22) }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 14, y: 2, width: max(0, bounds.width - 28), height: 18)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        label.textColor = .labelColor
        needsDisplay = true
    }
}

/// Same section treatment as ACEMenu: a non-actionable 24 pt row, a 16 pt icon,
/// and an appearance-aware background. Width is supplied by its natural content.
@MainActor
final class MonitorSectionHeaderView: NSView {
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private let preferredWidth: CGFloat
    private let titleX: CGFloat

    init(title: String, symbol: String?) {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        titleField = label
        let x: CGFloat = symbol == nil ? 14 : 31
        titleX = x
        preferredWidth = ceil(x + label.fittingSize.width + 12)
        super.init(frame: NSRect(x: 0, y: 0, width: preferredWidth, height: 24))
        autoresizingMask = [.width]
        if let symbol { iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        addSubview(titleField)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 24) }
    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 11, y: 4, width: 16, height: 16)
        titleField.frame = NSRect(x: titleX, y: 3, width: max(0, bounds.width - titleX - 8), height: 18)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch effectiveAppearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .darkAqua,
                                                    .accessibilityHighContrastAqua, .aqua]) {
        case .accessibilityHighContrastDarkAqua: color = .white.withAlphaComponent(0.18)
        case .darkAqua: color = .white.withAlphaComponent(0.10)
        case .accessibilityHighContrastAqua: color = .black.withAlphaComponent(0.14)
        default: color = .black.withAlphaComponent(0.07)
        }
        color.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        titleField.textColor = .labelColor
        needsDisplay = true
    }
}
