import AppKit
import SwiftUI
import Carbon.HIToolbox
import UniformTypeIdentifiers

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the full-screen launcher window: showing, hiding, and keyboard / scroll handling.
@MainActor
final class LauncherController {
    let store: LaunchpadStore
    private let panel: LauncherPanel
    private var monitors: [Any] = []
    private var swipeAccum: CGFloat = 0
    private var lastWheelPage = Date.distantPast
    private var hiding = false
    private var optionJiggle = false

    var isVisible: Bool { panel.isVisible && !hiding }

    init(store: LaunchpadStore) {
        self.store = store
        panel = LauncherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Sit just under the Dock so it stays visible, like the original Launchpad.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        panel.contentView = Self.blurredHost(LaunchpadView(store: store))

        store.dismiss = { [weak self] in self?.hide() }
        store.chooseApps = { [weak self] in self?.chooseApps() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func toggle() { isVisible ? hide() : show() }

    /// Sizes the window and the grid for a screen. Called on open and whenever displays change.
    private func fit(to screen: NSScreen) {
        panel.setFrame(screen.frame, display: true)
        // The menu bar auto-hides while open, so only the camera notch (if any) limits the top.
        // Measure the Dock before our presentation options hide it, and keep at least that much room.
        let dock = max(screen.visibleFrame.minY - screen.frame.minY, store.screenInsets.bottom)
        store.screenInsets = EdgeInsets(top: screen.safeAreaInsets.top, leading: 0, bottom: dock, trailing: 0)
        let grid = GridLayout.fittingGrid(size: screen.frame.size, insets: store.screenInsets)
        store.setGrid(columns: grid.columns, rows: grid.rows)
    }

    @objc private func screensChanged() {
        guard isVisible else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        fit(to: screen)
    }

    /// SwiftUI content over a frosted-glass blur of whatever is on screen behind the window.
    private static func blurredHost(_ view: some View) -> NSView {
        let blur = ClearGlassView()
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    func show() {
        hiding = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        store.screenInsets = EdgeInsets()
        fit(to: screen)

        store.query = ""
        store.openFolderID = nil
        store.showingOrganizer = false
        store.clearUndo()
        store.swipeOffset = 0
        store.reload()

        panel.alphaValue = 0
        NSApp.activate()
        // macOS only lets the menu bar hide together with the Dock; the Dock still slides up on hover.
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil) // keep the search field idle until the user types
        DispatchQueue.main.async { [panel] in (panel.contentView as? ClearGlassView)?.stripTint() }
        installMonitors()
        withAnimation(.snappy(duration: 0.3)) { store.isShown = true }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        removeMonitors()
        store.cancelDrag()
        store.isEditing = false
        store.closeFolder()
        withAnimation(.easeIn(duration: 0.16)) { store.isShown = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hiding else { return }
                self.panel.orderOut(nil)
                NSApp.presentationOptions = []
                self.hiding = false
                if NSApp.isActive && !NSApp.windows.contains(where: { $0.isVisible && $0 !== self.panel && $0.level == .normal }) {
                    NSApp.hide(nil) // return focus to the previous app
                }
            }
        })
    }

    /// "Add Application…": pick apps from anywhere on disk to put on the grid.
    private func chooseApps() {
        let open = NSOpenPanel()
        open.message = "Choose apps to add to Launchpad"
        open.prompt = "Add"
        open.allowedContentTypes = [.applicationBundle]
        open.allowsMultipleSelection = true
        open.treatsFilePackagesAsDirectories = false
        open.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        open.level = NSWindow.Level(rawValue: panel.level.rawValue + 1) // above the full-screen launcher
        open.begin { [weak self] response in
            guard response == .OK, let self else { return }
            withAnimation(.spring(duration: 0.35)) { _ = self.store.addApps(open.urls) }
        }
    }

    // MARK: Event handling

    private func installMonitors() {
        removeMonitors()
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        } as Any)
        // Holding Option jiggles the icons, like the original Launchpad.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.window === self.panel, !self.store.editingFolderName else { return event }
            let option = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            if option != self.optionJiggle, self.store.drag == nil {
                self.optionJiggle = option
                withAnimation(.spring(duration: 0.3)) { self.store.isEditing = option }
            }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleScroll(event) ? nil : event
        } as Any)
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let searching = !store.query.isEmpty
        let columns = store.gridColumns
        switch Int(event.keyCode) {
        case kVK_Escape:
            if store.drag != nil { store.cancelDrag() }
            else if store.showingOrganizer { withAnimation(.spring(duration: 0.3)) { store.showingOrganizer = false } }
            else if store.isEditing { withAnimation(.spring(duration: 0.3)) { store.isEditing = false } }
            else if store.openFolderID != nil { withAnimation(.spring(duration: 0.34, bounce: 0.05)) { store.closeFolder() } }
            else if searching { store.query = "" }
            else { hide() }
            return true
        case kVK_LeftArrow where !searching && !store.editingFolderName:
            withAnimation(.snappy(duration: 0.32)) { store.goToPage(store.currentPage - 1) }
            return true
        case kVK_RightArrow where !searching && !store.editingFolderName:
            withAnimation(.snappy(duration: 0.32)) { store.goToPage(store.currentPage + 1) }
            return true
        case kVK_LeftArrow where searching: return moveSelection(-1)
        case kVK_RightArrow where searching: return moveSelection(1)
        case kVK_UpArrow where searching: return moveSelection(-columns)
        case kVK_DownArrow where searching: return moveSelection(columns)
        case kVK_Tab where searching: return moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
        case kVK_Return where searching:
            store.launchSelection()
            return true
        case kVK_ANSI_Comma where event.modifierFlags.contains(.command):
            store.openSettings?()
            return true
        case kVK_ANSI_W where event.modifierFlags.contains(.command):
            hide()
            return true
        default:
            return typeIntoSearch(event)
        }
    }

    /// Type-to-search: while the search field isn't focused, typed characters go straight into the query and
    /// the field is asked to take focus, so nothing is lost while focus moves over.
    private func typeIntoSearch(_ event: NSEvent) -> Bool {
        guard !(panel.firstResponder is NSText), // a field is already being edited
              store.openFolderID == nil, !store.showingOrganizer,
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              let chars = event.characters, let first = chars.unicodeScalars.first,
              !(0xF700...0xF8FF).contains(first.value), // arrow / function keys
              !chars.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !(store.query.isEmpty && chars.trimmingCharacters(in: .whitespaces).isEmpty)
        else { return false }
        store.query += chars
        store.searchFocusRequest += 1
        return true
    }

    private func moveSelection(_ delta: Int) -> Bool {
        let count = store.searchResults.count
        guard count > 0 else { return true }
        store.selection = max(0, min(count - 1, store.selection + delta))
        return true
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard store.query.isEmpty, store.openFolderID == nil, !store.showingOrganizer else { return false }
        let width = panel.frame.width
        if event.hasPreciseScrollingDeltas {
            // Trackpad: follow the fingers, then snap to a page.
            if event.phase == .began { swipeAccum = 0 }
            if event.phase == .began || event.phase == .changed {
                let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                swipeAccum += delta
                var offset = swipeAccum
                let atStart = store.currentPage == 0 && offset > 0
                let atEnd = store.currentPage == store.pageCount - 1 && offset < 0
                if atStart || atEnd { offset *= 0.3 } // rubber band
                store.swipeOffset = offset
            } else if event.phase == .ended || event.phase == .cancelled {
                let threshold = width * 0.12
                var target = store.currentPage
                if swipeAccum < -threshold { target += 1 } else if swipeAccum > threshold { target -= 1 }
                withAnimation(.snappy(duration: 0.32)) {
                    store.goToPage(target)
                    store.swipeOffset = 0
                }
                swipeAccum = 0
            }
            return true
        }
        // Mouse wheel: one notch flips one page.
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard abs(delta) > 0.5, Date().timeIntervalSince(lastWheelPage) > 0.35 else { return true }
        lastWheelPage = Date()
        withAnimation(.snappy(duration: 0.32)) { store.goToPage(store.currentPage + (delta < 0 ? 1 : -1)) }
        return true
    }
}

/// A behind-window blur with the system tint removed, so the background keeps its true colors.
final class ClearGlassView: NSVisualEffectView {
    var blurRadius: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .fullScreenUI
        blendingMode = .behindWindow
        state = .active
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        stripTint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stripTint()
    }

    // The material's layers are (re)built lazily when the view draws, so strip after every update.
    override func updateLayer() {
        super.updateLayer()
        stripTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stripTint()
    }

    /// The material is a backdrop layer (blur + saturation) under "fill", "tone" and chameleon tint layers.
    /// Keep only the blur.
    /// Only the material layer (the one holding the CABackdropLayer) is touched; sibling layers,
    /// like the SwiftUI content's, are left alone.
    func stripTint() {
        for material in layer?.sublayers ?? [] {
            let parts = material.sublayers ?? []
            guard parts.contains(where: { String(describing: type(of: $0)) == "CABackdropLayer" }) else { continue }
            for part in parts {
                let kind = String(describing: type(of: part))
                if kind == "CABackdropLayer" {
                    let filters = (part.filters ?? []).compactMap { $0 as? NSObject }
                    let blur = filters.filter { ($0.value(forKey: "name") as? String) == "gaussianBlur" }
                    blur.forEach { $0.setValue(blurRadius, forKey: "inputRadius") }
                    if blur.count != filters.count { part.filters = blur }
                } else if (part.name == "fill" || part.name == "tone" || kind.contains("Chameleon")) && !part.isHidden {
                    part.isHidden = true
                }
            }
        }
    }
}
