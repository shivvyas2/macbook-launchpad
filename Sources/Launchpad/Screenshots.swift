import AppKit
import CoreImage
import SwiftUI

/// Renders marketing screenshots of the real UI: `Launchpad --render-screenshots <folder>`.
/// Liquid Glass can't be captured offscreen, so while rendering, glass surfaces draw as frosted fills.
@MainActor
enum Screenshots {
    static var isRendering = false

    static func render(to folder: URL) {
        isRendering = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = CGSize(width: 1728, height: 1080)
        let background = wallpaper(size: size)

        // The real installed apps in a showcase arrangement, never touching the user's saved layout.
        let store = LaunchpadStore(persistsLayout: false)
        store.screenInsets = EdgeInsets()
        let grid = GridLayout.fittingGrid(size: size, insets: store.screenInsets)
        store.setGrid(columns: grid.columns, rows: grid.rows)
        store.showLayout(showcase(store, slots: grid.columns * grid.rows))
        store.isShown = true

        capture(store, size: size, background: background, to: folder.appendingPathComponent("grid.jpg"))

        if let folderID = store.entries.compactMap(\.folder).max(by: { $0.apps.count < $1.apps.count })?.id {
            store.openFolderID = folderID
            capture(store, size: size, background: background, to: folder.appendingPathComponent("folder.jpg"))
            store.openFolderID = nil
        }

        store.query = "ph"
        capture(store, size: size, background: background, to: folder.appendingPathComponent("search.jpg"))
        store.query = ""

        // The assistant, proposing folders for a not-yet-organized library.
        let fresh = LaunchpadStore(persistsLayout: false)
        fresh.screenInsets = EdgeInsets()
        fresh.setGrid(columns: grid.columns, rows: grid.rows)
        fresh.showLayout(byName(Array(fresh.apps.values)).map { .app($0.id) })
        fresh.isShown = true
        fresh.showingOrganizer = true
        capture(fresh, size: size, background: background, to: folder.appendingPathComponent("organize.jpg"))
    }

    /// Four folders up front, then well-known apps filling the rest of the first page.
    private static func showcase(_ store: LaunchpadStore, slots: Int) -> [LayoutEntry] {
        let all = Array(store.apps.values)
        let plan = Organizer.plan(for: all)
        let folderNames = ["Developer", "Creative", "Productivity", "Social"]
        let folders = folderNames.compactMap { name in plan.first { $0.name == name } }
        let inFolders = Set(folders.flatMap(\.apps))
        // Skip helpers and installers that nobody would put on a first page.
        let noise = ["helper", "installer", "uninstall", "url handler", "service", "client", "cleanup", "agent",
                     "diagnostic", "assistant", "setup", "utility", "launchpad", "plus", "manager"]
        let loose = byName(all.filter { app in
            !inFolders.contains(app.id) && !noise.contains { app.name.lowercased().contains($0) }
        })
        let apps = loose.prefix(max(0, slots - folders.count)).map { LayoutEntry.app($0.id) }
        return folders.map { .folder($0) } + apps
    }

    private static func byName(_ apps: [AppInfo]) -> [AppInfo] {
        apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func capture(_ store: LaunchpadStore, size: CGSize, background: NSImage, to url: URL) {
        let host = NSHostingView(rootView: LaunchpadView(store: store))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8)) // let icons and layout settle

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let ui = NSImage(size: size)
        ui.addRepresentation(rep)

        let output = NSImage(size: size)
        output.lockFocus()
        background.draw(in: NSRect(origin: .zero, size: size))
        ui.draw(in: NSRect(origin: .zero, size: size))
        output.unlockFocus()

        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        pixels.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
        output.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? pixels.representation(using: .jpeg, properties: [.compressionFactor: 0.88])?.write(to: url)
        window.close()
    }

    /// A blurred, Tahoe-like color field standing in for the desktop.
    private static func wallpaper(size: CGSize) -> NSImage {
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSGradient(colors: [NSColor(srgbRed: 0.07, green: 0.09, blue: 0.30, alpha: 1),
                            NSColor(srgbRed: 0.22, green: 0.16, blue: 0.60, alpha: 1)])!
            .draw(in: NSRect(origin: .zero, size: size), angle: -70)
        let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (0.12, 0.88, 0.55, NSColor(srgbRed: 0.95, green: 0.38, blue: 0.70, alpha: 0.8)),
            (0.88, 0.82, 0.6, NSColor(srgbRed: 0.22, green: 0.56, blue: 1.0, alpha: 0.85)),
            (0.55, 0.10, 0.7, NSColor(srgbRed: 0.48, green: 0.26, blue: 0.95, alpha: 0.85)),
            (0.04, 0.08, 0.4, NSColor(srgbRed: 0.10, green: 0.74, blue: 0.95, alpha: 0.6)),
        ]
        for (x, y, r, color) in blobs {
            color.setFill()
            let d = r * size.width
            NSBezierPath(ovalIn: NSRect(x: x * size.width - d / 2, y: y * size.height - d / 2, width: d, height: d)).fill()
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let source = CIImage(data: tiff) else { return canvas }
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: 110).cropped(to: source.extent)
        guard let cg = CIContext().createCGImage(blurred, from: source.extent) else { return canvas }
        return NSImage(cgImage: cg, size: size)
    }
}

extension View {
    /// Liquid Glass, or a frosted stand-in while rendering screenshots.
    @MainActor @ViewBuilder
    func launchpadGlass(_ glass: Glass = .regular, in shape: some Shape) -> some View {
        if Screenshots.isRendering {
            self.background(Color.white.opacity(0.16), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.3), lineWidth: 1))
        } else {
            self.glassEffect(glass, in: shape)
        }
    }
}
