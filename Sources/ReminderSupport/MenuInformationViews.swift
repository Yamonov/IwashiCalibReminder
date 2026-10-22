import AppKit

/// A disabled native title is dimmed by AppKit. A non-interactive custom view owns
/// its drawing and keeps the normal label color in light, dark, and high contrast.
@MainActor
public enum ReadableMenuInformation {
    public static func item(_ title: String, secondary: Bool = false, maximumWidth: CGFloat? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = title
        item.view = InformationRowView(title: title, secondary: secondary, maximumWidth: maximumWidth)
        return item
    }
}

@MainActor
private final class InformationRowView: NSView {
    private let label: NSTextField
    private let preferredWidth: CGFloat
    private let secondary: Bool
    init(title: String, secondary: Bool, maximumWidth: CGFloat?) {
        self.secondary = secondary
        let field = NSTextField(labelWithString: title)
        field.font = secondary ? .systemFont(ofSize: 12) : .menuFont(ofSize: 13)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = maximumWidth == nil ? .byClipping : .byTruncatingMiddle
        field.isSelectable = false
        label = field
        preferredWidth = min(ceil(field.fittingSize.width) + 28, maximumWidth ?? .greatestFiniteMagnitude)
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
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        needsDisplay = true
    }
}
