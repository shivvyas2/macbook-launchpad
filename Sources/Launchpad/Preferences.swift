import AppKit
import Carbon.HIToolbox
import Observation

enum ScreenCorner: String, CaseIterable, Identifiable {
    case none, topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Off"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: [.option])

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let name = special[Int(code)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay),
                           0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// User settings, persisted in UserDefaults.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var hotKey: HotKeyCombo {
        didSet {
            defaults.set(Int(hotKey.keyCode), forKey: "hotKeyCode")
            defaults.set(Int(hotKey.modifiers.rawValue), forKey: "hotKeyModifiers")
        }
    }
    var hotCorner: ScreenCorner { didSet { defaults.set(hotCorner.rawValue, forKey: "hotCorner") } }
    var pinchEnabled: Bool { didSet { defaults.set(pinchEnabled, forKey: "pinchEnabled") } }
    var pinchFingers: Int { didSet { defaults.set(pinchFingers, forKey: "pinchFingers") } }
    var columns: Int { didSet { defaults.set(columns, forKey: "columns") } }
    var rows: Int { didSet { defaults.set(rows, forKey: "rows") } }
    var iconSize: Double { didSet { defaults.set(iconSize, forKey: "iconSize") } }

    private init() {
        defaults.register(defaults: [
            "hotKeyCode": Int(HotKeyCombo.default.keyCode),
            "hotKeyModifiers": Int(HotKeyCombo.default.modifiers.rawValue),
            "hotCorner": ScreenCorner.none.rawValue,
            "pinchEnabled": true,
            "pinchFingers": 4,
            "columns": 7,
            "rows": 5,
            "iconSize": 88.0,
        ])
        hotKey = HotKeyCombo(keyCode: UInt32(defaults.integer(forKey: "hotKeyCode")),
                             modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "hotKeyModifiers"))))
        hotCorner = ScreenCorner(rawValue: defaults.string(forKey: "hotCorner") ?? "") ?? .none
        pinchEnabled = defaults.bool(forKey: "pinchEnabled")
        pinchFingers = defaults.integer(forKey: "pinchFingers")
        columns = defaults.integer(forKey: "columns")
        rows = defaults.integer(forKey: "rows")
        iconSize = defaults.double(forKey: "iconSize")
    }
}
