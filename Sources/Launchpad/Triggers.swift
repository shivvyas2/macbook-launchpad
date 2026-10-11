import AppKit
import Carbon.HIToolbox
import MultitouchBridge

/// System-wide keyboard shortcut via Carbon (needs no Accessibility permission).
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    func register(_ combo: HotKeyCombo) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let id = EventHotKeyID(signature: OSType(0x4C50_4144), id: 1) // 'LPAD'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Hot key registration failed: \(status)") }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// Polls the pointer position; fires when it rests in the chosen screen corner.
@MainActor
final class HotCorner {
    private var timer: Timer?
    private var enteredAt: Date?
    private var fired = false
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    func update(_ corner: ScreenCorner) {
        timer?.invalidate()
        timer = nil
        guard corner != .none else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(corner) }
        }
    }

    private func tick(_ corner: ScreenCorner) {
        let p = NSEvent.mouseLocation
        let inCorner = NSScreen.screens.contains { screen in
            let f = screen.frame, slop: CGFloat = 3
            let left = p.x <= f.minX + slop, right = p.x >= f.maxX - slop
            let bottom = p.y <= f.minY + slop, top = p.y >= f.maxY - slop
            guard f.insetBy(dx: -1, dy: -1).contains(p) else { return false }
            switch corner {
            case .topLeft: return top && left
            case .topRight: return top && right
            case .bottomLeft: return bottom && left
            case .bottomRight: return bottom && right
            case .none: return false
            }
        }
        guard inCorner else { enteredAt = nil; fired = false; return }
        if enteredAt == nil { enteredAt = Date() }
        if !fired, let start = enteredAt, Date().timeIntervalSince(start) > 0.2 {
            fired = true
            action()
        }
    }
}

/// Detects a multi-finger pinch-in on the trackpad (thumb + three fingers, like the old Launchpad gesture).
final class PinchDetector: @unchecked Sendable {
    nonisolated(unsafe) static var shared: PinchDetector?

    private let action: @MainActor () -> Void
    private let fingers: Int
    // Touched only on the multitouch thread.
    private var startSpread: Float?
    private var fired = false

    private init(fingers: Int, action: @escaping @MainActor () -> Void) {
        self.fingers = fingers
        self.action = action
    }

    @discardableResult
    static func start(fingers: Int, action: @escaping @MainActor () -> Void) -> Int {
        mtb_stop()
        shared = PinchDetector(fingers: fingers, action: action)
        return Int(mtb_start { count, xs, ys, _ in
            guard let xs, let ys else { return }
            PinchDetector.shared?.frame(count: Int(count), xs: xs, ys: ys)
        })
    }

    static func stop() {
        mtb_stop()
        shared = nil
    }

    private func frame(count: Int, xs: UnsafePointer<Float>, ys: UnsafePointer<Float>) {
        guard count >= fingers else {
            if count == 0 { startSpread = nil; fired = false }
            return
        }
        var cx: Float = 0, cy: Float = 0
        for i in 0..<count { cx += xs[i]; cy += ys[i] }
        cx /= Float(count); cy /= Float(count)
        var spread: Float = 0
        for i in 0..<count {
            let dx = xs[i] - cx, dy = (ys[i] - cy) * 0.7 // trackpads are wider than tall
            spread += (dx * dx + dy * dy).squareRoot()
        }
        spread /= Float(count)

        guard let start = startSpread else { startSpread = spread; return }
        if !fired, start > 0.08, spread < start * 0.55 {
            fired = true
            let action = self.action
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
    }
}
