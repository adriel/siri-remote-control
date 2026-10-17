// Renders the app icon (a Siri Remote glyph on a dark rounded square) into <outdir>/AppIcon.icns.
// Usage: swift scripts/make-icon.swift <outdir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.08, alpha: 1)])!.draw(in: bg, angle: -90)
    // The same flat remote as the menu bar icon (Sources/RemoteControl/UI/MenuBarIcon.swift), in white.
    let h = rect.height * 0.62
    let w = h * 9.5 / 16
    let body = NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h)
    let unit = w / 9.5
    let flip = { (y: CGFloat) in body.maxY - y }  // the glyph is specified top-down; this context is bottom-up
    let glyph = NSBezierPath(roundedRect: body, xRadius: 2 * unit, yRadius: 2 * unit)
    func circle(_ x: CGFloat, _ yFromTop: CGFloat, _ r: CGFloat) {
        glyph.append(NSBezierPath(ovalIn: NSRect(x: x - r, y: flip(yFromTop) - r, width: r * 2, height: r * 2)))
    }
    circle(body.midX, 4.6 * unit, 3.15 * unit)
    circle(body.midX, 4.6 * unit, 1.5 * unit)
    circle(body.midX - 2.05 * unit, 10.6 * unit, 0.95 * unit)
    circle(body.midX + 2.05 * unit, 10.6 * unit, 0.95 * unit)
    glyph.windingRule = .evenOdd
    NSColor(white: 0.94, alpha: 1).setFill()
    glyph.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote \(outDir.appendingPathComponent("AppIcon.icns").path)")
