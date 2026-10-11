import SwiftUI

/// The icon being dragged: where it came from, where the pointer is, and where the icon sits relative to it.
struct DragState: Equatable {
    enum Source: Equatable {
        case grid
        case folder(UUID)
    }

    var id: String              // top-level entry id, or the app path when dragging inside a folder
    var source: Source
    var grabOffset: CGSize      // icon center minus pointer
    var iconSize: CGFloat
}

/// The pointer during a drag. Kept apart from the store's other state so that moving the mouse only
/// re-renders the floating icon, never the grid.
@MainActor @Observable
final class DragPointer {
    var location: CGPoint = .zero   // in the "launchpad" coordinate space
    var settling = false            // true while the icon glides into its final slot
}

/// Coordinate space shared by the drag gesture, cell frames and the floating icon.
let launchpadSpace = "launchpad"

extension EnvironmentValues {
    /// Namespace for the folder open/close morph (folder ↔ panel, mini icon ↔ full icon).
    @Entry var launchpadNamespace: Namespace.ID? = nil
}

// MARK: - Drag engine

extension LaunchpadStore {
    static func frameKey(_ id: String, inFolder: Bool) -> String { (inFolder ? "f:" : "g:") + id }

    /// Center of the icon inside a cell (the label sits below it).
    static func iconCenter(in frame: CGRect, iconSize: CGFloat) -> CGPoint {
        let labelBlock = 7 + iconSize * 0.155 * 1.25
        return CGPoint(x: frame.midX, y: frame.midY - labelBlock / 2)
    }

    func beginDrag(_ id: String, source: DragState.Source, at start: CGPoint, iconSize: CGFloat) {
        guard drag == nil else { return }
        let inFolder = source != .grid
        let frame = cellFrames[Self.frameKey(id, inFolder: inFolder)] ?? CGRect(origin: start, size: .zero)
        let center = Self.iconCenter(in: frame, iconSize: iconSize)
        folderTargetID = nil
        pointer.location = start
        pointer.settling = false
        drag = DragState(id: id, source: source,
                         grabOffset: CGSize(width: center.x - start.x, height: center.y - start.y), iconSize: iconSize)
        if !isEditing { withAnimation(.snappy(duration: 0.25)) { isEditing = true } }
    }

    func updateDrag(to point: CGPoint) {
        guard let current = drag, !pointer.settling else { return }
        pointer.location = point

        switch current.source {
        case .folder(let folderID):
            // Leaving the panel pulls the app out onto the grid and closes the folder, like the original.
            if folderPanelFrame != .zero, !folderPanelFrame.insetBy(dx: -16, dy: -16).contains(point) {
                cancelPending()
                withAnimation(.spring(duration: 0.38, bounce: 0.1)) {
                    removeFromFolder(folderID, app: current.id)
                    closeFolder()
                }
                drag?.source = .grid
                return
            }
            guard let target = hit(point, inFolder: true), target != current.id else { cancelPending(); return }
            schedule("f:\(target)", after: 0.12) { [weak self] in
                withAnimation(.snappy(duration: 0.28)) { self?.moveInFolder(folderID, app: current.id, to: target) }
            }

        case .grid:
            // Rest at a screen edge to flip pages.
            if point.x < 56 || point.x > viewportWidth - 56 {
                let direction = point.x < 56 ? -1 : 1
                schedule("edge\(direction)", after: 0.6, repeats: true) { [weak self] in
                    guard let self else { return }
                    withAnimation(.snappy(duration: 0.32)) { self.goToPage(self.currentPage + direction) }
                }
                return
            }
            guard let target = hit(point, inFolder: false), let frame = cellFrames[Self.frameKey(target, inFolder: false)] else {
                // Past the last icon on a page: move to the end of that page.
                if gridArea.contains(point), let lastFrame = lastFrameOnPage, point.y > lastFrame.minY || point.x > lastFrame.maxX {
                    clearFolderTarget()
                    schedule("end\(currentPage)", after: 0.25) { [weak self] in
                        guard let self else { return }
                        withAnimation(.snappy(duration: 0.28)) { self.moveToEnd(current.id, page: self.currentPage) }
                    }
                } else {
                    cancelPending()
                }
                return
            }
            guard target != current.id else { cancelPending(); clearFolderTarget(); return }
            // Over the middle of an icon: make (or add to) a folder. Over its sides: take its place.
            let relativeX = (point.x - frame.minX) / frame.width
            let draggingApp = !current.id.hasPrefix("folder:")
            if draggingApp && relativeX > 0.25 && relativeX < 0.75 {
                schedule("merge:\(target)", after: 0.3) { [weak self] in
                    withAnimation(.snappy(duration: 0.22, extraBounce: 0.1)) { self?.folderTargetID = target }
                }
            } else {
                clearFolderTarget()
                schedule("move:\(target)", after: 0.15) { [weak self] in
                    withAnimation(.snappy(duration: 0.28)) { self?.move(current.id, to: target) }
                }
            }
        }
    }

    func endDrag() {
        cancelPending()
        guard let current = drag else { return }
        var landing = cellFrames[Self.frameKey(current.id, inFolder: current.source != .grid)]
        if current.source == .grid, let target = folderTargetID {
            landing = cellFrames[Self.frameKey(target, inFolder: false)]
            withAnimation(.snappy(duration: 0.3, extraBounce: 0.08)) { merge(current.id, into: target) }
        }
        folderTargetID = nil
        save()

        // Glide the floating icon into its slot, then hand over to the real cell.
        guard let landing else { drag = nil; return }
        let center = Self.iconCenter(in: landing, iconSize: current.iconSize)
        withAnimation(.snappy(duration: 0.2)) {
            pointer.settling = true
            pointer.location = CGPoint(x: center.x - current.grabOffset.width, y: center.y - current.grabOffset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.pointer.settling else { return }
            self.drag = nil
            self.pointer.settling = false
        }
    }

    func cancelDrag() {
        cancelPending()
        drag = nil
        pointer.settling = false
        folderTargetID = nil
    }

    // MARK: Helpers

    private func hit(_ point: CGPoint, inFolder: Bool) -> String? {
        let prefix = inFolder ? "f:" : "g:"
        return cellFrames.first { key, frame in
            key.hasPrefix(prefix) && frame.contains(point) && frame.minX >= -1 && frame.maxX <= viewportWidth + 1
        }.map { String($0.key.dropFirst(2)) }
    }

    /// Union of the visible page's cells, used to detect drops in the empty space after the last icon.
    private var gridArea: CGRect {
        visiblePageFrames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: 0, dy: -40)
    }

    private var lastFrameOnPage: CGRect? {
        let ids = page(currentPage).map(\.id)
        return ids.last.flatMap { cellFrames[Self.frameKey($0, inFolder: false)] }
    }

    private var visiblePageFrames: [CGRect] {
        page(currentPage).compactMap { cellFrames[Self.frameKey($0.id, inFolder: false)] }
    }

    private func clearFolderTarget() {
        if folderTargetID != nil { withAnimation(.spring(duration: 0.25)) { folderTargetID = nil } }
    }

    /// Runs `action` once the pointer has rested on the same target for `delay`.
    private func schedule(_ key: String, after delay: TimeInterval, repeats: Bool = false, _ action: @escaping @MainActor () -> Void) {
        guard pendingKey != key else { return }
        cancelPending()
        pendingKey = key
        func arm() {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pendingKey == key, self.drag != nil else { return }
                MainActor.assumeIsolated { action() }
                if repeats { arm() } else { self.pendingKey = nil }
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        arm()
    }

    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
        pendingKey = nil
    }
}

// MARK: - View helpers

extension View {
    /// Reports this cell's frame so the drag engine can hit-test it.
    func reportsFrame(_ key: String, to store: LaunchpadStore) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(launchpadSpace)) } action: { frame in
            store.cellFrames[key] = frame
        }
        .onDisappear { store.cellFrames[key] = nil }
    }

    /// The drag-to-rearrange gesture shared by grid and folder cells.
    func arrangeGesture(_ store: LaunchpadStore, id: String, source: DragState.Source, iconSize: CGFloat) -> some View {
        gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(launchpadSpace))
                .onChanged { value in
                    store.beginDrag(id, source: source, at: value.startLocation, iconSize: iconSize)
                    store.updateDrag(to: value.location)
                }
                .onEnded { _ in store.endDrag() }
        )
    }

    /// The classic Launchpad jiggle while arranging.
    func wiggle(_ active: Bool, seed: String) -> some View {
        modifier(Wiggle(active: active, seed: seed))
    }
}

private struct Wiggle: ViewModifier {
    let active: Bool
    let seed: String

    private struct Pose {
        var angle: Double = 0
        var lift: Double = 0
    }

    func body(content: Content) -> some View {
        // Apple's jiggle: a small tilt (about 1.2°) on a roughly half-second cycle, with a slight vertical
        // bob out of step with it. Each icon gets its own period and direction so the grid never moves in
        // lockstep. Keyframes only drive the transform, so nothing is redrawn while it plays.
        let hash = abs(seed.hashValue)
        let half = 0.23 + Double(hash % 7) * 0.008          // 0.23 to 0.28 s per swing
        let tilt = (hash % 2 == 0 ? 1.0 : -1.0) * 1.2
        let bob = 0.6
        // When inactive the animator rests at the initial (upright) pose, without changing view identity.
        content.keyframeAnimator(initialValue: Pose(), repeating: active) { view, pose in
            view
                .rotationEffect(.degrees(pose.angle))
                .offset(y: pose.lift)
        } keyframes: { _ in
            KeyframeTrack(\.angle) {
                CubicKeyframe(tilt, duration: half / 2)
                CubicKeyframe(-tilt, duration: half)
                CubicKeyframe(0, duration: half / 2)
            }
            KeyframeTrack(\.lift) {
                CubicKeyframe(-bob, duration: half * 0.75)
                CubicKeyframe(bob, duration: half)
                CubicKeyframe(0, duration: half * 0.25)
            }
        }
    }
}

/// The lifted icon that follows the pointer.
struct DragGhost: View {
    let store: LaunchpadStore
    let drag: DragState

    var body: some View {
        let pointer = store.pointer
        let center = CGPoint(x: pointer.location.x + drag.grabOffset.width, y: pointer.location.y + drag.grabOffset.height)
        Group {
            if drag.id.hasPrefix("folder:"), let folder = store.entries.lazy.compactMap(\.folder).first(where: { "folder:" + $0.id.uuidString == drag.id }) {
                FolderIcon(store: store, folder: folder, size: drag.iconSize, matched: false)
            } else {
                Image(nsImage: IconCache.shared.icon(for: drag.id))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: drag.iconSize, height: drag.iconSize)
            }
        }
        .scaleEffect(pointer.settling ? 1 : 1.1)
        .position(center)
        .allowsHitTesting(false)
    }
}
