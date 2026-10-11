import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

struct SettingsView: View {
    let store: LaunchpadStore
    let hotKey: HotKey
    @Bindable private var prefs = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Open Launchpad") {
                LabeledContent("Keyboard shortcut") {
                    HotKeyRecorder(combo: $prefs.hotKey, hotKey: hotKey)
                }
                Picker("Hot corner", selection: $prefs.hotCorner) {
                    ForEach(ScreenCorner.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Trackpad pinch", isOn: $prefs.pinchEnabled)
                if prefs.pinchEnabled {
                    Picker("Fingers", selection: $prefs.pinchFingers) {
                        Text("Thumb + 3 fingers").tag(4)
                        Text("Thumb + 4 fingers").tag(5)
                    }
                    Text("Turn off the matching system gesture in System Settings › Trackpad › More Gestures so both don't fire. Clicking the Dock icon also opens Launchpad.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Layout") {
                Stepper("Columns: \(prefs.columns)", value: $prefs.columns, in: 4...12)
                Stepper("Rows: \(prefs.rows)", value: $prefs.rows, in: 3...8)
                LabeledContent("Icon size") {
                    Slider(value: $prefs.iconSize, in: 48...128, step: 4)
                        .frame(width: 200)
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Rescan Apps") { IconCache.shared.invalidate(); store.reload() }
                    Button("Show Hidden Apps (\(store.hiddenApps.count))") { store.unhideAll() }
                        .disabled(store.hiddenApps.isEmpty)
                    Spacer()
                    Button("Reset Layout…", role: .destructive) { confirmReset() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset layout?"
        alert.informativeText = "All folders are removed and apps are sorted alphabetically."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.resetLayout() }
    }
}

struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo
    let hotKey: HotKey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press shortcut…" : combo.displayString) {
            recording ? stop() : start()
        }
        .frame(minWidth: 120)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hotKey.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let code = Int(event.keyCode)
            if code == kVK_Escape && mods.isEmpty { stop(); return nil }
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            guard !mods.isEmpty || functionKeys.contains(code) else { NSSound.beep(); return nil }
            combo = HotKeyCombo(keyCode: UInt32(code), modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotKey.register(combo)
    }
}
