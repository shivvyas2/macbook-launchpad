import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = LaunchpadStore()
    private(set) lazy var launcher = LauncherController(store: store)
    private lazy var hotKey = HotKey { [weak self] in self?.launcher.toggle() }
    private lazy var hotCorner = HotCorner { [weak self] in
        guard let self, !self.launcher.isVisible else { return }
        self.launcher.show()
    }
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        store.openSettings = { [weak self] in self?.showSettings() }
        applyPreferences()
        observePreferences()

        // Stay out of the way when started at login; otherwise open right away.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin { launcher.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon toggles the launcher.
        launcher.toggle()
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        launcher.hide()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Preferences

    func applyPreferences() {
        let prefs = Preferences.shared
        hotKey.register(prefs.hotKey)
        hotCorner.update(prefs.hotCorner)
        if prefs.pinchEnabled {
            let devices = PinchDetector.start(fingers: prefs.pinchFingers) { [weak self] in
                guard let self, !self.launcher.isVisible else { return }
                self.launcher.show()
            }
            if devices <= 0 { NSLog("Pinch gesture unavailable (devices: \(devices))") }
        } else {
            PinchDetector.stop()
        }
    }

    private func observePreferences() {
        withObservationTracking {
            let prefs = Preferences.shared
            _ = (prefs.hotKey, prefs.hotCorner, prefs.pinchEnabled, prefs.pinchFingers)
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.applyPreferences()
                self?.observePreferences()
            }
        }
    }

    // MARK: Windows & menu

    @objc func showSettings() {
        launcher.hide()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Launchpad Settings"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store, hotKey: hotKey))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showLauncher() { launcher.show() }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Launchpad", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Show Launchpad", action: #selector(showLauncher), keyEquivalent: "l")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Launchpad", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Launchpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        return main
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--render-screenshots"), i + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated { Screenshots.render(to: folder) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
