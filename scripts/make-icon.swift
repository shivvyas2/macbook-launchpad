// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
// Style: the classic macOS Launchpad icon — a graphite squircle holding a 3x3 grid of glossy colored tiles.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

// Top row first. Each tile is a light-to-dark vertical gradient.
let tiles: [(NSColor, NSColor)] = [
    (rgb(255, 106, 96), rgb(232, 48, 62)),    // red
    (rgb(255, 176, 64), rgb(250, 128, 30)),   // orange
    (rgb(255, 222, 84), rgb(247, 186, 32)),   // yellow
    (rgb(120, 222, 110), rgb(52, 186, 72)),   // green
    (rgb(96, 214, 236), rgb(30, 168, 214)),   // teal
    (rgb(92, 160, 255), rgb(36, 104, 240)),   // blue
    (rgb(150, 132, 255), rgb(98, 76, 230)),   // indigo
    (rgb(212, 128, 255), rgb(164, 70, 226)),  // purple
    (rgb(255, 120, 186), rgb(234, 62, 136)),  // pink
]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px)

    // macOS icon grid: 824/1024 body, centered, with a soft drop shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset + s * 0.008, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSGradient(colors: [rgb(92, 94, 102), rgb(46, 47, 53), rgb(28, 29, 33)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Glass rim: bright top edge fading to nothing.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.16), .white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.003, dy: s * 0.003), xRadius: radius, yRadius: radius)
    rim.lineWidth = max(0.5, s * 0.005)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    rim.stroke()

    // 3x3 tiles.
    let grid = body.width * 0.64
    let gap = grid * 0.085
    let tile = (grid - gap * 2) / 3
    let origin = NSPoint(x: body.midX - grid / 2, y: body.midY - grid / 2)
    for (i, colors) in tiles.enumerated() {
        let row = 2 - i / 3, col = i % 3
        let r = NSRect(x: origin.x + CGFloat(col) * (tile + gap), y: origin.y + CGFloat(row) * (tile + gap), width: tile, height: tile)
        let p = NSBezierPath(roundedRect: r, xRadius: tile * 0.26, yRadius: tile * 0.26)

        NSGraphicsContext.saveGraphicsState()
        let tileShadow = NSShadow()
        tileShadow.shadowColor = .black.withAlphaComponent(0.45)
        tileShadow.shadowBlurRadius = s * 0.012
        tileShadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
        tileShadow.set()
        NSGradient(starting: colors.0, ending: colors.1)!.draw(in: p, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Gloss on the upper half of each tile.
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSGradient(colors: [.white.withAlphaComponent(0.45), .white.withAlphaComponent(0.05)])!
            .draw(in: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
