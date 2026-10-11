import SwiftUI

/// Hovering the middle of an icon targets it for a folder; hovering its edges reorders.
struct GridDropDelegate: DropDelegate {
    let store: LaunchpadStore
    let target: LayoutEntry
    let cell: CGSize

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let dragged = store.draggingID, dragged != target.id, store.index(of: dragged) != nil else {
            return DropProposal(operation: .move)
        }
        let x = info.location.x / cell.width
        let draggedIsApp = !dragged.hasPrefix("folder:")
        if draggedIsApp && x > 0.25 && x < 0.75 {
            if store.folderTargetID != target.id { store.folderTargetID = target.id }
        } else {
            if store.folderTargetID != nil { store.folderTargetID = nil }
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { store.move(dragged, to: target.id) }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if store.folderTargetID == target.id { store.folderTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragged = store.draggingID, store.folderTargetID == target.id {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { store.merge(dragged, into: target.id) }
        }
        store.folderTargetID = nil
        store.draggingID = nil
        store.save()
        return true
    }
}

/// Reorders apps inside an open folder.
struct FolderReorderDelegate: DropDelegate {
    let store: LaunchpadStore
    let folderID: UUID
    let target: String

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let dragged = store.draggingID, dragged != target {
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { store.moveInFolder(folderID, app: dragged, to: target) }
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.draggingID = nil
        store.save()
        return true
    }
}

/// Dropping an app outside the open folder pulls it out onto the grid.
struct FolderExitDropDelegate: DropDelegate {
    let store: LaunchpadStore
    let folderID: UUID

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if let dragged = store.draggingID {
            withAnimation(.spring(duration: 0.35)) {
                store.removeFromFolder(folderID, app: dragged)
                store.closeFolder()
            }
        }
        store.draggingID = nil
        return true
    }
}

/// Flips pages while a dragged icon rests against the screen edge.
struct EdgeFlipDelegate: DropDelegate {
    let store: LaunchpadStore
    let direction: Int
    private let timer = TimerBox()

    init(store: LaunchpadStore, direction: Int) {
        self.store = store
        self.direction = direction
    }

    func dropEntered(info: DropInfo) {
        timer.start(interval: 0.7) { [store, direction] in
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { store.goToPage(store.currentPage + direction) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropExited(info: DropInfo) { timer.stop() }

    func performDrop(info: DropInfo) -> Bool {
        timer.stop()
        if let dragged = store.draggingID { store.moveToEnd(dragged, page: store.currentPage) }
        store.draggingID = nil
        store.folderTargetID = nil
        store.save()
        return true
    }
}

/// Ends any drag that lands somewhere without a more specific drop target.
struct EndDragDelegate: DropDelegate {
    let store: LaunchpadStore

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropExited(info: DropInfo) { store.folderTargetID = nil }

    func performDrop(info: DropInfo) -> Bool {
        store.draggingID = nil
        store.folderTargetID = nil
        store.save()
        return true
    }
}

@MainActor
final class TimerBox {
    private var timer: Timer?

    func start(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
