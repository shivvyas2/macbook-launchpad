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
    var wallpaper: NSImage?
    var screenInsets = EdgeInsets()
    var screenSize = CGSize(width: 1440, height: 900)

    /// Apps the user chose to hide from the grid and search.
    private(set) var hiddenApps: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenApps), forKey: "hiddenApps") }
    }
    var editingFolderName = false

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
        if folder.apps.isEmpty {
            entries.remove(at: i)
            if openFolderID == id { openFolderID = nil }
        } else if folder.apps.count == 1 && openFolderID != id {
            entries[i] = .app(folder.apps[0]) // a folder of one dissolves
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
        dissolveFolderIfSingle(id)
    }

    func dissolveFolderIfSingle(_ folderID: UUID) {
        guard let i = entries.firstIndex(where: { $0.folder?.id == folderID }), let folder = entries[i].folder, folder.apps.count == 1 else { return }
        entries[i] = .app(folder.apps[0])
        save()
    }

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
        let categories = paths.compactMap { path -> String? in
            guard let bundle = Bundle(path: path), let type = bundle.infoDictionary?["LSApplicationCategoryType"] as? String else { return nil }
            return type
        }
        if let first = categories.first, categories.allSatisfy({ $0 == first }) {
            let raw = first.replacingOccurrences(of: "public.app-category.", with: "")
            let pretty: [String: String] = [
                "developer-tools": "Developer", "productivity": "Productivity", "social-networking": "Social",
                "utilities": "Utilities", "graphics-design": "Design", "photography": "Photos",
                "music": "Music", "video": "Video", "games": "Games", "entertainment": "Entertainment",
                "business": "Business", "finance": "Finance", "education": "Education",
                "news": "News", "reference": "Reference", "lifestyle": "Lifestyle", "travel": "Travel",
                "health-fitness": "Health", "weather": "Weather", "sports": "Sports",
            ]
            return pretty[raw] ?? raw.replacingOccurrences(of: "-", with: " ").capitalized
        }
        return "Folder"
    }
}
