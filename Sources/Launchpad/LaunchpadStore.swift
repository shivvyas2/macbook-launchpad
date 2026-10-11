import AppKit
import SwiftUI
import Observation

/// All launcher state: installed apps, the user's arrangement, and transient UI state.
@MainActor @Observable
final class LaunchpadStore {
    private(set) var apps: [String: AppInfo] = [:]
    private(set) var entries: [LayoutEntry] = []

    // Transient UI state
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var selection = 0
    var currentPage = 0
    var swipeOffset: CGFloat = 0
    var openFolderID: UUID?
    var draggingID: String?
    var folderTargetID: String?
    var isShown = false
    var screenInsets = EdgeInsets()

    /// Apps the user chose to hide from the grid and search.
    private(set) var hiddenApps: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenApps), forKey: "hiddenApps") }
    }
    var editingFolderName = false
    var showingOrganizer = false

    var dismiss: (() -> Void)?
    var openSettings: (() -> Void)?

    private let layoutURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Launchpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }()

    var perPage: Int { max(1, Preferences.shared.columns * Preferences.shared.rows) }
    var pageCount: Int { max(1, Int(ceil(Double(entries.count) / Double(perPage)))) }

    func page(_ index: Int) -> ArraySlice<LayoutEntry> {
        let start = index * perPage
        guard start < entries.count else { return [] }
        return entries[start..<min(entries.count, start + perPage)]
    }

    var openFolder: Folder? {
        guard let id = openFolderID else { return nil }
        return entries.lazy.compactMap(\.folder).first { $0.id == id }
    }

    // MARK: Loading

    init() {
        if let data = try? Data(contentsOf: layoutURL),
           let saved = try? JSONDecoder().decode([LayoutEntry].self, from: data) {
            entries = saved
        }
        reload()
    }

    /// Rescans the disk and reconciles the saved layout: drops uninstalled apps, appends new ones.
    func reload() {
        let scanned = AppScanner.scan().filter { !hiddenApps.contains($0.id) }
        apps = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var placed = Set<String>()
        var reconciled: [LayoutEntry] = []
        for entry in entries {
            switch entry {
            case .app(let path):
                if apps[path] != nil, placed.insert(path).inserted { reconciled.append(entry) }
            case .folder(var folder):
                folder.apps = folder.apps.filter { apps[$0] != nil && placed.insert($0).inserted }
                if !folder.apps.isEmpty { reconciled.append(.folder(folder)) }
            }
        }
        let newApps = scanned.filter { !placed.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        reconciled += newApps.map { .app($0.id) }

        if reconciled != entries {
            entries = reconciled
            save()
        }
        currentPage = min(currentPage, pageCount - 1)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: layoutURL, options: .atomic)
    }

    func hide(_ app: AppInfo) {
        hiddenApps.insert(app.id)
        reload()
    }

    func unhideAll() {
        hiddenApps = []
        reload()
    }

    func resetLayout() {
        entries = []
        openFolderID = nil
        currentPage = 0
        reload()
        save()
    }

    // MARK: Search

    var searchResults: [AppInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        func score(_ app: AppInfo) -> Int? {
            let name = app.name.lowercased()
            if name == q { return 0 }
            if name.hasPrefix(q) { return 1 }
            let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
            if words.contains(where: { $0.hasPrefix(q) }) { return 2 }
            let initials = String(words.compactMap(\.first))
            if initials.hasPrefix(q) { return 3 }
            if name.contains(q) { return 4 }
            if let bundle = app.bundleID?.lowercased(), bundle.contains(q) { return 5 }
            return nil
        }
        let scored: [(app: AppInfo, rank: Int)] = apps.values.compactMap { app in
            guard let rank = score(app) else { return nil }
            return (app, rank)
        }
        return scored.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending
        }.map(\.app)
    }

    // MARK: Actions

    func launch(_ app: AppInfo) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error { NSLog("Launch failed: \(error.localizedDescription)") }
        }
        dismiss?()
    }

    func launchSelection() {
        let results = searchResults
        guard results.indices.contains(selection) else { return }
        launch(results[selection])
    }

    func showInFinder(_ app: AppInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
        dismiss?()
    }

    func goToPage(_ page: Int) {
        currentPage = max(0, min(pageCount - 1, page))
    }

    // MARK: Arranging

    func index(of id: String) -> Int? { entries.firstIndex { $0.id == id } }

    /// Moves the dragged top-level entry to the slot currently held by `targetID`.
    func move(_ id: String, to targetID: String) {
        guard id != targetID, let from = index(of: id), let to = index(of: targetID) else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: to)
    }

    func moveToEnd(_ id: String, page: Int) {
        guard let from = index(of: id) else { return }
        let entry = entries.remove(at: from)
        let end = min(entries.count, (page + 1) * perPage - 1)
        entries.insert(entry, at: max(0, end))
    }

    /// Drops the dragged app onto another app (creating a folder) or onto a folder (adding to it).
    func merge(_ id: String, into targetID: String) {
        guard id != targetID, let fromIndex = index(of: id), case .app(let path) = entries[fromIndex],
              let targetIndex = index(of: targetID) else { return }
        switch entries[targetIndex] {
        case .app(let targetPath):
            let name = suggestedFolderName(for: [targetPath, path])
            entries[targetIndex] = .folder(Folder(id: UUID(), name: name, apps: [targetPath, path]))
        case .folder(var folder):
            folder.apps.append(path)
            entries[targetIndex] = .folder(folder)
        }
        entries.remove(at: fromIndex)
        save()
    }

    func updateFolder(_ id: UUID, _ change: (inout Folder) -> Void) {
        guard let i = entries.firstIndex(where: { $0.folder?.id == id }), var folder = entries[i].folder else { return }
        change(&folder)
        if folder.apps.isEmpty && openFolderID != id {
            entries.remove(at: i) // an empty folder disappears once it's closed
        } else {
            entries[i] = .folder(folder)
        }
        save()
    }

    func moveInFolder(_ folderID: UUID, app: String, to target: String) {
        updateFolder(folderID) { folder in
            guard let from = folder.apps.firstIndex(of: app), let to = folder.apps.firstIndex(of: target), from != to else { return }
            folder.apps.insert(folder.apps.remove(at: from), at: to)
        }
    }

    /// Pulls an app out of a folder and places it right after the folder.
    func removeFromFolder(_ folderID: UUID, app: String) {
        guard let i = entries.firstIndex(where: { $0.folder?.id == folderID }) else { return }
        entries.insert(.app(app), at: i + 1)
        updateFolder(folderID) { $0.apps.removeAll { $0 == app } }
    }

    func closeFolder() {
        guard let id = openFolderID else { return }
        openFolderID = nil
        editingFolderName = false
        updateFolder(id) { _ in }
    }

    /// Creates a folder (optionally around an app, taking its slot) and opens it for naming.
    func createFolder(with app: String? = nil) {
        let folder = Folder(id: UUID(), name: "New Folder", apps: app.map { [$0] } ?? [])
        if let app, let i = index(of: app) {
            entries[i] = .folder(folder)
        } else {
            let end = min(entries.count, (currentPage + 1) * perPage)
            entries.insert(.folder(folder), at: end)
            if end >= (currentPage + 1) * perPage { goToPage(currentPage + 1) }
        }
        openFolderID = folder.id
        save()
    }

    /// Moves an app into a folder, from the grid or from another folder.
    func addToFolder(_ folderID: UUID, app: String) {
        if let i = index(of: app) {
            entries.remove(at: i)
        } else if let other = folderContaining(app), other.id != folderID {
            updateFolder(other.id) { $0.apps.removeAll { $0 == app } }
        }
        updateFolder(folderID) { if !$0.apps.contains(app) { $0.apps.append(app) } }
    }

    /// Apps sitting directly on the grid, i.e. not inside any folder.
    var looseApps: [AppInfo] {
        entries.compactMap { entry in
            if case .app(let path) = entry { return apps[path] }
            return nil
        }
    }

    // MARK: Organize assistant

    private(set) var undoEntries: [LayoutEntry]?

    /// Replaces the layout with the given folders, then every remaining app alphabetically.
    func applyOrganization(_ plan: [Folder], keepExistingFolders: Bool) {
        undoEntries = entries
        var folders: [Folder] = keepExistingFolders ? entries.compactMap(\.folder) : []
        let planned = Set(plan.flatMap(\.apps))
        for i in folders.indices { folders[i].apps.removeAll { planned.contains($0) } }
        for proposal in plan {
            if let i = folders.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(proposal.name) == .orderedSame }) {
                folders[i].apps += proposal.apps
            } else {
                folders.append(proposal)
            }
        }
        folders.removeAll { $0.apps.isEmpty }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let inFolders = Set(folders.flatMap(\.apps))
        let loose = apps.values.filter { !inFolders.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        entries = folders.map { .folder($0) } + loose.map { .app($0.id) }
        currentPage = 0
        save()
    }

    func undoOrganization() {
        guard let previous = undoEntries else { return }
        entries = previous
        undoEntries = nil
        reload()
        save()
    }

    func clearUndo() { undoEntries = nil }

    func ungroup(_ folderID: UUID) {
        guard let i = entries.firstIndex(where: { $0.folder?.id == folderID }), let folder = entries[i].folder else { return }
        entries.replaceSubrange(i...i, with: folder.apps.map { .app($0) })
        if openFolderID == folderID { openFolderID = nil }
        save()
    }

    func folderContaining(_ app: String) -> Folder? {
        entries.lazy.compactMap(\.folder).first { $0.apps.contains(app) }
    }

    private func suggestedFolderName(for paths: [String]) -> String {
        let names = Set(paths.compactMap { apps[$0] }.map(Organizer.folderName(for:)))
        if names.count == 1, let name = names.first, name != Organizer.other { return name }
        return "Folder"
    }

}
