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
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
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
        if !fired, let start = enteredAt, Date().timeIntervalSince(start) > 0.12 {
            fired = true
            action()
        }
    }
}

/// Detects a multi-finger pinch-in on the trackpad (thumb + three fingers, like the old Launchpad gesture).
///
/// Only a deliberate pinch fires: exactly the chosen number of fingers on the glass, all of them closing in on
/// a common center, within a short time. Swipes, scrolls, resting fingers and fingers landing or lifting
/// one at a time (which shift the center and fake a shrinking spread) don't count.
final class PinchDetector: @unchecked Sendable {
    nonisolated(unsafe) static var shared: PinchDetector?

    private struct Baseline {
        var ids: [Int32]
        var distances: [Int32: Float] // each finger's distance from the center
        var spread: Float
        var cx: Float, cy: Float
        var time: Double
    }

    private let action: @MainActor () -> Void
    private let fingers: Int
    // Touched only on the multitouch thread.
    private var baseline: Baseline?
    private var fired = false

    private init(fingers: Int, action: @escaping @MainActor () -> Void) {
        self.fingers = fingers
        self.action = action
    }

    @discardableResult
    static func start(fingers: Int, action: @escaping @MainActor () -> Void) -> Int {
        mtb_stop()
        shared = PinchDetector(fingers: fingers, action: action)
        return Int(mtb_start { count, xs, ys, ids, timestamp in
            guard let xs, let ys, let ids else { return }
            PinchDetector.shared?.frame(count: Int(count), xs: xs, ys: ys, ids: ids, time: timestamp)
        })
    }

    static func stop() {
        mtb_stop()
        shared = nil
    }

    /// Fingers must start at least this far apart (normalized trackpad units), so a small cluster can't fire.
    private static let minStartSpread: Float = 0.1
    /// The spread must shrink to this fraction of where it started.
    private static let closeRatio: Float = 0.6
    /// Every finger must move at least this much closer to the center (as a fraction of its start distance).
    private static let fingerCloseRatio: Float = 0.8
    /// A pinch that takes longer than this restarts from the current position, so slow drift never adds up.
    private static let window: Double = 0.6

    private func frame(count: Int, xs: UnsafePointer<Float>, ys: UnsafePointer<Float>, ids: UnsafePointer<Int32>, time: Double) {
        if count == 0 { baseline = nil; fired = false; return }
        // Wait for every finger to lift after firing, and ignore any other finger count entirely.
        guard !fired, count == fingers else { baseline = nil; return }

        var cx: Float = 0, cy: Float = 0
        for i in 0..<count { cx += xs[i]; cy += ys[i] }
        cx /= Float(count); cy /= Float(count)
        var distances: [Int32: Float] = [:]
        var spread: Float = 0
        for i in 0..<count {
            let dx = xs[i] - cx, dy = (ys[i] - cy) * 0.7 // trackpads are wider than tall
            let d = (dx * dx + dy * dy).squareRoot()
            distances[ids[i]] = d
            spread += d
        }
        spread /= Float(count)
        let fingerIDs = (0..<count).map { ids[$0] }.sorted()
        let current = Baseline(ids: fingerIDs, distances: distances, spread: spread, cx: cx, cy: cy, time: time)

        // A different set of fingers, or a gesture that has dragged on, starts over from here.
        guard let start = baseline, start.ids == fingerIDs, time - start.time <= Self.window else {
            baseline = current
            return
        }
        guard start.spread >= Self.minStartSpread, spread < start.spread * Self.closeRatio else { return }
        // All fingers converge (rules out one finger sliding while the others rest)...
        let allClosing = start.distances.allSatisfy { id, d0 in
            (distances[id] ?? .infinity) < d0 * Self.fingerCloseRatio
        }
        // ...and the hand stays put (rules out multi-finger swipes, which move the center a lot).
        let drift = ((cx - start.cx) * (cx - start.cx) + (cy - start.cy) * (cy - start.cy)).squareRoot()
        guard allClosing, drift < start.spread * 0.5 else { return }

        fired = true
        baseline = nil
        let action = self.action
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }
}
