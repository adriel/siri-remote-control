import AppKit

/// The menu bar glyph: a flat remote (rounded body, ring-shaped clickpad, two buttons), drawn as a template
/// image so macOS tints it for light and dark menu bars. Trackpad mode adds a small pointer badge.
enum MenuBarIcon {
    static func image(trackpad: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let body = NSRect(x: trackpad ? 2.0 : 4.25, y: 1, width: 9.5, height: 16)
            glyph(in: body).fill()
            if trackpad, let context = NSGraphicsContext.current {
                let arrow = pointer(tip: NSPoint(x: 11.3, y: 10.0), scale: 0.85)
                // Punch a halo out of the body so the badge reads as separate.
                context.compositingOperation = .destinationOut
                arrow.lineWidth = 2.4
                arrow.lineJoinStyle = .round
                arrow.stroke()
                arrow.fill()
                context.compositingOperation = .sourceOver
                arrow.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = trackpad ? "Remote Control, trackpad mode" : "Remote Control"
        return image
    }

    /// The remote outline with the clickpad ring and buttons cut out (even-odd fill), scaled to `body`.
    static func glyph(in body: NSRect) -> NSBezierPath {
        let unit = body.width / 9.5
        let path = NSBezierPath(roundedRect: body, xRadius: 2 * unit, yRadius: 2 * unit)
        let center = NSPoint(x: body.midX, y: body.minY + 4.6 * unit)
        path.append(circle(center, radius: 3.15 * unit))   // ring outer edge (cut out)
        path.append(circle(center, radius: 1.5 * unit))    // ring centre (filled again)
        for dx in [-2.05, 2.05] {
            path.append(circle(NSPoint(x: body.midX + dx * unit, y: body.minY + 10.6 * unit), radius: 0.95 * unit))
        }
        path.windingRule = .evenOdd
        return path
    }

    private static func circle(_ c: NSPoint, radius r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// A classic arrow pointer with its tip at `tip` (flipped coordinates).
    private static func pointer(tip: NSPoint, scale: CGFloat) -> NSBezierPath {
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 7.4), (1.8, 5.8), (3.0, 8.4), (4.2, 7.9), (3.0, 5.3), (5.4, 5.3)]
        let path = NSBezierPath()
        for (i, p) in points.enumerated() {
            let point = NSPoint(x: tip.x + p.0 * scale, y: tip.y + p.1 * scale)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
