import Foundation

/// Sorts apps into folders by what they are: well-known apps by name, everything else by the
/// App Store category in its Info.plist.
enum Organizer {
    static let other = "Other"

    /// Name / bundle-ID fragments for apps whose category is missing or too broad. Checked in order.
    private static let rules: [(folder: String, keywords: [String])] = [
        ("AI", ["claude", "chatgpt", "openai", "perplexity", "gemini", "copilot", "ollama", "lm studio", "msty", "jan.ai"]),
        ("Developer", ["xcode", "visual studio", "vscode", "cursor", "zed", "terminal", "iterm", "warp", "ghostty", "github",
                       "gitkraken", "sourcetree", "tower", "docker", "postman", "insomnia", "simulator", "instruments",
                       "android studio", "intellij", "pycharm", "webstorm", "jetbrains", "sublime", "nova", "idle",
                       "python", "markchart", "testflight", "tableplus", "sequel", "dbeaver", "proxyman", "charles", "console", "script editor",
                       "developer", "reality composer", "sf symbols"]),
        ("Creative", ["adobe", "photoshop", "lightroom", "illustrator", "premiere", "after effects", "acrobat", "creative cloud",
                      "figma", "sketch", "blender", "affinity", "pixelmator", "canva", "procreate", "final cut", "motion",
                      "compressor", "davinci", "capcut", "logic pro", "garageband", "mainstage", "artcraft", "lightcraft", "cinema",
                      "addictive keys", "ilok", "heavyocity", "native instruments", "kontakt"]),
        ("Social", ["slack", "discord", "whatsapp", "telegram", "signal", "messenger", "messages", "facetime", "zoom", "teams",
                    "skype", "webex", "mail", "spark", "outlook", "superhuman", "linkedin", "wechat", "line", "phone"]),
        ("Productivity", ["notion", "obsidian", "bear", "craft", "things", "todoist", "omnifocus", "reminders", "notes", "calendar",
                          "fantastical", "linear", "clickup", "asana", "trello", "jira", "monday", "microsoft word", "excel",
                          "powerpoint", "onenote", "journal", "freeform", "pages", "numbers", "keynote", "google docs", "google sheets", "google slides",
                          "google drive", "dropbox", "onedrive", "box", "1password", "bitwarden", "raycast", "alfred", "contacts"]),
        ("Media", ["music", "spotify", "tv", "podcasts", "vlc", "iina", "infuse", "plex", "netflix", "youtube", "photos",
                   "image capture", "photo booth", "quicktime", "books", "kindle", "audible", "news", "stocks", "dvd player",
                   "stremio", "image playground"]),
        ("Browsers", ["safari", "chrome", "firefox", "brave", "arc", "microsoft edge", "opera", "vivaldi", "orion", "zen browser", "dia"]),
        ("Games", ["steam", "epic games", "battle.net", "chess", "minecraft", "game center", "games", "x-plane", "whisky"]),
        ("Utilities", ["utility", "utilities", "activity monitor", "disk", "system information", "migration", "keychain",
                       "bluetooth", "airport", "audio midi", "colorsync", "boot camp", "automator", "shortcuts", "screenshot",
                       "voiceover", "digital color", "font book", "preview", "textedit", "calculator", "clock", "weather",
                       "maps", "find my", "home", "passwords", "system settings", "app store", "stickies", "time machine",
                       "printer", "installer", "uninstall", "cleaner", "betterdisplay", "bartender", "rectangle", "magnet",
                       "logi", "focusrite", "karabiner", "amphetamine", "appcleaner", "the unarchiver", "keka", "uninstaller",
                       "iphone mirroring", "desk view", "feedback assistant", "folder actions", "license manager",
                       "screen sharing", "magnifier", "voice memos"]),
    ]

    private static let categories: [String: String] = [
        "developer-tools": "Developer",
        "graphics-design": "Creative", "photography": "Creative", "video": "Creative",
        "music": "Media", "entertainment": "Media", "books": "Media", "news": "Media",
        "social-networking": "Social",
        "productivity": "Productivity", "business": "Productivity",
        "utilities": "Utilities",
        "games": "Games",
        "finance": "Finance",
        "education": "Learning", "reference": "Learning",
        "lifestyle": "Lifestyle", "travel": "Lifestyle", "health-fitness": "Lifestyle", "medical": "Lifestyle",
        "weather": "Lifestyle", "sports": "Lifestyle", "food-and-drink": "Lifestyle", "navigation": "Lifestyle",
        "shopping": "Lifestyle",
    ]

    static func folderName(for app: AppInfo) -> String {
        // Match both "QuickTime" as written and camel-split ("ClaudeCodeMonitor" → "claude code monitor").
        let plain = words(app.name, splitCamelCase: false), split = words(app.name, splitCamelCase: true)
        let names = [plain.joined(separator: " "), split.joined(separator: " ")]
        let nameWords = Set(plain + split)
        // The app's name is the strongest signal; its bundle ID is a fallback (web apps share their browser's ID).
        for rule in rules where rule.keywords.contains(where: { keyword in
            keyword.contains(" ") || keyword.contains(".") || keyword.contains("-")
                ? names.contains { $0.contains(keyword) } : nameWords.contains(keyword)
        }) {
            return rule.folder
        }
        let bundleParts = Set((app.bundleID?.lowercased() ?? "").split(separator: ".").dropFirst().map(String.init))
        for rule in rules where rule.keywords.contains(where: bundleParts.contains) {
            return rule.folder
        }
        if let info = Bundle(url: app.url)?.infoDictionary,
           let category = info["LSApplicationCategoryType"] as? String {
            let key = category.replacingOccurrences(of: "public.app-category.", with: "")
            if key.hasSuffix("-games") { return "Games" }
            if let folder = categories[key] { return folder }
        }
        if app.id.contains("/Utilities/") { return "Utilities" }
        return other
    }

    /// Lowercased words of a name, splitting camel case: "ClaudeCodeMonitor" → ["claude", "code", "monitor"].
    private static func words(_ name: String, splitCamelCase: Bool) -> [String] {
        var spaced = ""
        var previous: Character?
        for char in name {
            if splitCamelCase, let previous, char.isUppercase, previous.isLowercase { spaced.append(" ") }
            spaced.append(char)
            previous = char
        }
        return spaced.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "." })
            .map(String.init)
    }

    /// Proposed folders for the given apps. Groups of one stay loose, as does anything unrecognised.
    static func plan(for apps: [AppInfo]) -> [Folder] {
        let grouped = Dictionary(grouping: apps, by: folderName(for:))
        return grouped
            .filter { $0.key != other && $0.value.count >= 2 }
            .map { name, apps in
                Folder(id: UUID(), name: name,
                       apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.id))
            }
            .sorted { $0.name < $1.name }
    }
}
