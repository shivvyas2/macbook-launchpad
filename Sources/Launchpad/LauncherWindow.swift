import AppKit
import SwiftUI
import Carbon.HIToolbox

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
    }

    func toggle() { isVisible ? hide() : show() }

    /// SwiftUI content over a behind-window blur, used when no wallpaper image is available.
    private static func blurredHost(_ view: some View) -> NSView {
        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
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
        panel.setFrame(screen.frame, display: true)

        store.query = ""
        store.openFolderID = nil
        store.swipeOffset = 0
        store.reload()
        store.wallpaper = Wallpaper.blurred(for: screen)
        // The menu bar auto-hides while open, so only the camera notch (if any) limits the top.
        store.screenInsets = EdgeInsets(top: screen.safeAreaInsets.top, leading: 0,
                                        bottom: screen.visibleFrame.minY - screen.frame.minY, trailing: 0)
        store.screenSize = screen.frame.size

        panel.alphaValue = 0
        NSApp.activate()
        // macOS only lets the menu bar hide together with the Dock; the Dock still slides up on hover.
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { store.isShown = true }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        removeMonitors()
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

    // MARK: Event handling

    private func installMonitors() {
        removeMonitors()
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
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
        let columns = Preferences.shared.columns
        switch Int(event.keyCode) {
        case kVK_Escape:
            if store.openFolderID != nil { withAnimation(.spring(duration: 0.3)) { store.closeFolder() } }
            else if searching { store.query = "" }
            else { hide() }
            return true
        case kVK_LeftArrow where !searching && !store.editingFolderName:
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { store.goToPage(store.currentPage - 1) }
            return true
        case kVK_RightArrow where !searching && !store.editingFolderName:
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { store.goToPage(store.currentPage + 1) }
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
            return false
        }
    }

    private func moveSelection(_ delta: Int) -> Bool {
        let count = store.searchResults.count
        guard count > 0 else { return true }
        store.selection = max(0, min(count - 1, store.selection + delta))
        return true
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard store.query.isEmpty, store.openFolderID == nil else { return false }
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
                withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
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
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { store.goToPage(store.currentPage + (delta < 0 ? 1 : -1)) }
        return true
    }
}
