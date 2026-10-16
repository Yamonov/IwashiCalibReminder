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

    public static func make(status: ReminderStatusGraph, showsUpdateIndicator: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let count = status.segments.count
            if count > 0 {
                let width = inside.width / Double(count)
                for (index, segment) in status.segments.enumerated() {
                    // The column order matches the stable monitor numbers in the menu.
                    let leftGap: Double = index == 0 ? 0 : min(0.5, width / 8)
                    let rightGap: Double = index == count - 1 ? 0 : min(0.5, width / 8)
                    let column = NSRect(x: inside.minX + Double(index) * width + leftGap,
                                        y: inside.minY, width: width - leftGap - rightGap, height: inside.height)
                    drawFill(segment.graph, rect: column, opacity: segment.isStale ? 0.35 : 1)
                    NSGraphicsContext.saveGraphicsState()
                    let left = index == 0 ? 0 : inside.minX + Double(index) * width
                    let right = index == count - 1 ? size.width : inside.minX + Double(index + 1) * width
                    NSGraphicsContext.current?.cgContext.clip(to: NSRect(x: left, y: 0, width: right - left, height: size.height))
                    NSGraphicsContext.current?.cgContext.setAlpha(segment.isStale ? 0.35 : 1)
                    drawFrame()
                    NSGraphicsContext.restoreGraphicsState()
                }
            } else { drawFrame() }
            if let label = status.earliest?.label { drawLabel(label) }
            if showsUpdateIndicator { drawUpdateIndicator() }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawUpdateIndicator() {
        // Same proportions and colors as Scripta and ACEMenu.
        let diameter = floor(min(size.width, size.height) * 0.5)
        let rect = NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter)
        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let inset = max(1.2, diameter * 0.18)
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
    }

    private static func drawFill(_ graph: ReminderGraph, rect: NSRect = inside, opacity: Double = 1) {
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
        NSGraphicsContext.current?.cgContext.setAlpha(opacity)
        color.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * fraction).fill()
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
