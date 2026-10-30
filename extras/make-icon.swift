// Draws the app icon into an .iconset: `swift extras/make-icon.swift <dir>.iconset`, then `iconutil -c icns`.
// Three board rows on a dark tile, each led by a status dot in the board's own colors.
import AppKit

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(in ctx: CGContext, size: CGFloat) {
    let u = size / 1024
    // Apple's grid: an 824 tile centered on the 1024 canvas.
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * u, yRadius: 185 * u)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.set()
    color(0x17191d).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [color(0x2b2f37), color(0x1a1c21), color(0x121317)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
    NSGradient(colors: [color(0x339cff, 0.28), color(0x339cff, 0)])!
        .draw(fromCenter: CGPoint(x: tile.midX, y: tile.maxY - 120 * u), radius: 0,
              toCenter: CGPoint(x: tile.midX, y: tile.maxY - 120 * u), radius: 560 * u, options: [])
    NSGraphicsContext.restoreGraphicsState()

    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2 * u, dy: 2 * u), xRadius: 183 * u, yRadius: 183 * u)
    rim.lineWidth = 4 * u
    NSColor.white.withAlphaComponent(0.09).setStroke()
    rim.stroke()

    let rows: [(dot: Int, width: CGFloat, lit: Bool)] = [(0x339cff, 400, true), (0xff8549, 330, false), (0x3ed598, 370, false)]
    let rowH: CGFloat = 150 * u, gap: CGFloat = 46 * u
    let left = tile.minX + 92 * u, right = tile.maxX - 92 * u
    var top = tile.midY + (rowH * 1.5 + gap)
    for row in rows {
        let r = CGRect(x: left, y: top - rowH, width: right - left, height: rowH)
        let card = NSBezierPath(roundedRect: r, xRadius: 38 * u, yRadius: 38 * u)
        (row.lit ? NSColor.white.withAlphaComponent(0.11) : NSColor.white.withAlphaComponent(0.055)).setFill()
        card.fill()
        card.lineWidth = 3 * u
        (row.lit ? color(0x339cff, 0.55) : NSColor.white.withAlphaComponent(0.07)).setStroke()
        card.stroke()

        let dotR: CGFloat = 30 * u
        let dot = CGPoint(x: r.minX + 72 * u, y: r.midY)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color(row.dot, 0.9)
        glow.shadowBlurRadius = 34 * u
        glow.set()
        color(row.dot).setFill()
        NSBezierPath(ovalIn: CGRect(x: dot.x - dotR, y: dot.y - dotR, width: dotR * 2, height: dotR * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let textX = dot.x + 64 * u
        NSColor.white.withAlphaComponent(row.lit ? 0.85 : 0.6).setFill()
        NSBezierPath(roundedRect: CGRect(x: textX, y: r.midY + 6 * u, width: row.width * u, height: 26 * u),
                     xRadius: 13 * u, yRadius: 13 * u).fill()
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: CGRect(x: textX, y: r.midY - 40 * u, width: row.width * 0.6 * u, height: 20 * u),
                     xRadius: 10 * u, yRadius: 10 * u).fill()
        top -= rowH + gap
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = g
        draw(in: g.cgContext, size: CGFloat(px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
