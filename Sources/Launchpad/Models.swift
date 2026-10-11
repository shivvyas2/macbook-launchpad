import AppKit

/// An installed application found on disk.
struct AppInfo: Identifiable, Hashable {
    let id: String          // absolute path, stable across launches
    let name: String
    let url: URL
    let bundleID: String?
}

struct Folder: Codable, Hashable {
    var id: UUID
    var name: String
    var apps: [String]      // app paths
}

/// One slot in the top-level grid: either an app or a folder of apps.
enum LayoutEntry: Codable, Hashable, Identifiable {
    case app(String)
    case folder(Folder)

    var id: String {
        switch self {
        case .app(let path): path
        case .folder(let folder): "folder:" + folder.id.uuidString
        }
    }

    var folder: Folder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }
}

enum AppScanner {
    static let roots: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    /// Apps that live in the scanned folders but aren't useful to launch.
    static let hidden: Set<String> = [
        "/System/Library/CoreServices/Applications/Archive Utility.app",
        "/System/Library/CoreServices/Applications/Ticket Viewer.app",
        "/System/Library/CoreServices/Applications/Expansion Slot Utility.app",
        "/System/Library/CoreServices/Applications/Wireless Diagnostics.app",
        "/System/Library/CoreServices/Applications/About This Mac.app",
    ]

    static func scan() -> [AppInfo] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [AppInfo] = []

        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            guard !hidden.contains(path), seen.insert(path).inserted else { return }
            let bundle = Bundle(url: url)
            if let info = bundle?.infoDictionary,
               (info["LSUIElement"] as? Bool == true || info["LSUIElement"] as? String == "1"),
               !path.hasPrefix("/Applications") {
                return // background-only system agents
            }
            var name = fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            result.append(AppInfo(id: path, name: name, url: URL(fileURLWithPath: path), bundleID: bundle?.bundleIdentifier))
        }

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          !roots.contains(item.path) {
                    // One level of app folders, e.g. /Applications/Adobe Photoshop/Photoshop.app
                    let nested = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    nested.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        // Our own app shouldn't appear in its own grid.
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return result.filter { $0.id != me }
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let image = cache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 256, height: 256)
        cache[path] = image
        return image
    }

    func invalidate() { cache.removeAll() }
}
