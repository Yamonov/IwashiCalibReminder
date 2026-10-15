import AppKit
import CoreText

@MainActor
public enum GraphImage {
    public static let size = NSSize(width: 18, height: 18)
    private static let inside = NSRect(x: 2, y: 2, width: 14, height: 14)

    public static func make(graph: ReminderGraph) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            drawFill(graph)
            drawFrame()
            if let label = graph.label { drawLabel(label) }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawFill(_ graph: ReminderGraph) {
        guard let fraction = graph.fraction, fraction > 0 else { return }
        let color: NSColor
        switch graph.level {
        case .unknown: return
        case .normal: color = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.65)
        case .caution: color = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 0.65)
        case .warning, .overdue: color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.65)
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: inside, xRadius: 2, yRadius: 2).addClip()
        color.setFill()
        NSRect(x: inside.minX, y: inside.minY, width: inside.width, height: inside.height * fraction).fill()
    }

    private static func drawFrame() {
        // Retain the 1 pt stroke and 1 pt clear gap; the canvas itself is square.
        NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1).setStroke()
        let frame = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(roundedRect: frame, xRadius: 3.5, yRadius: 3.5)
        border.lineWidth = 1
        border.stroke()
    }

    private static func drawLabel(_ text: String) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        // Center the visible glyphs, including NG, rather than the font's line box.
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let available = inside.insetBy(dx: 0.5, dy: 0.5)
        let scale = min(1, available.width / bounds.width, available.height / bounds.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: inside)
        context.translateBy(x: inside.midX, y: inside.midY)
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
    }
}
