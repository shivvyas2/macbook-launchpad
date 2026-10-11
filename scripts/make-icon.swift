// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
// Style: the classic Launchpad 3x3 grid, drawn in the macOS 26 Liquid Glass idiom — a squircle body
// with a specular rim, and translucent glass tiles laid out concentrically inside it.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple system colors, top row first: (light top, deeper bottom).
let tiles: [(NSColor, NSColor)] = [
    (rgb(0xFF6B61), rgb(0xF2333A)), // red
    (rgb(0xFFB340), rgb(0xFF8A00)), // orange
    (rgb(0xFFE25A), rgb(0xFFC400)), // yellow
    (rgb(0x5BE37D), rgb(0x22B84C)), // green
    (rgb(0x7DEFF0), rgb(0x2FC7D6)), // mint
    (rgb(0x4DA6FF), rgb(0x0A6CFF)), // blue
    (rgb(0x8A88FF), rgb(0x5450E0)), // indigo
    (rgb(0xD98BFF), rgb(0xAE4BEA)), // purple
    (rgb(0xFF6F8E), rgb(0xF0305A)), // pink
]

/// Continuous-corner rounded square (the "squircle" Apple uses), as a superellipse of exponent n.
func squircle(_ r: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = r.width / 2, b = r.height / 2
    let steps = 240
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        let p = NSPoint(x: r.midX + x, y: r.midY + y)
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.close()
    return path
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.shouldAntialias = true
    let s = CGFloat(px)

    // macOS icon grid: an 824/1024 body centered in the canvas.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset + s * 0.006, width: s - inset * 2, height: s - inset * 2)
    let shape = squircle(body)

    // Drop shadow
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.028
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    rgb(0x16171F).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Body: deep blue-graphite with a soft glow from the upper left.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [rgb(0x3A3F55), rgb(0x1E2130), rgb(0x111219)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)
    NSGradient(colors: [rgb(0x6E7BFF, 0.35), rgb(0x6E7BFF, 0)])!
        .draw(fromCenter: NSPoint(x: body.minX + body.width * 0.25, y: body.maxY - body.height * 0.2), radius: 0,
              toCenter: NSPoint(x: body.minX + body.width * 0.25, y: body.maxY - body.height * 0.2), radius: body.width * 0.75,
              options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Specular rim: bright at the top-left, fading around the edge.
    NSGraphicsContext.saveGraphicsState()
    let rim = squircle(body.insetBy(dx: s * 0.004, dy: s * 0.004))
    rim.lineWidth = max(0.6, s * 0.007)
    shape.addClip()
    NSGraphicsContext.current?.cgContext.addPath(rim.cgPath)
    NSGraphicsContext.current?.cgContext.setLineWidth(rim.lineWidth)
    NSGraphicsContext.current?.cgContext.replacePathWithStrokedPath()
    NSGraphicsContext.current?.cgContext.clip()
    NSGradient(colors: [.white.withAlphaComponent(0.55), .white.withAlphaComponent(0.08), .white.withAlphaComponent(0.25)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -45)
    NSGraphicsContext.restoreGraphicsState()

    // 3x3 glass tiles, concentric with the body:
    //   tileRadius = bodyRadius - padding, and tileRadius = k * tile (tiles keep an icon shape).
    let side = body.width
    let bodyRadius = side * 0.225
    let gap = side * 0.06
    let k: CGFloat = 0.3
    let padding = (bodyRadius - k * (side - 2 * gap) / 3) / (1 - 2 * k / 3)
    let tile = (side - padding * 2 - gap * 2) / 3
    for (i, colors) in tiles.enumerated() {
        let row = 2 - i / 3, col = i % 3
        let r = NSRect(x: body.minX + padding + CGFloat(col) * (tile + gap),
                       y: body.minY + padding + CGFloat(row) * (tile + gap), width: tile, height: tile)
        let p = squircle(r)

        // Colored glow beneath the tile.
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = colors.1.withAlphaComponent(0.55)
        glow.shadowBlurRadius = s * 0.022
        glow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
        glow.set()
        NSGradient(starting: colors.0, ending: colors.1)!.draw(in: p, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Glass: a soft highlight over the top half and a bright rim along the top edge.
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSGradient(colors: [.white.withAlphaComponent(0.42), .white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: r.minX, y: r.midY - r.height * 0.05, width: r.width, height: r.height * 0.55), angle: -90)
        let edge = squircle(r.insetBy(dx: s * 0.002, dy: s * 0.002))
        NSGraphicsContext.current?.cgContext.addPath(edge.cgPath)
        NSGraphicsContext.current?.cgContext.setLineWidth(max(0.5, s * 0.004))
        NSGraphicsContext.current?.cgContext.replacePathWithStrokedPath()
        NSGraphicsContext.current?.cgContext.clip()
        NSGradient(colors: [.white.withAlphaComponent(0.85), .white.withAlphaComponent(0.1)])!.draw(in: r, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
