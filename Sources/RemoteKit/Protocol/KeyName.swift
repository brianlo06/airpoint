import Foundation

/// The keyboard allowlist.
///
/// Raw virtual keycodes are deliberately **never** accepted from the wire: a numeric keycode
/// field is an open door to whatever the host's keymap happens to contain, and it makes the
/// protocol untestable against a fixed contract. Clients name keys; the host maps names to
/// keycodes locally. Anything not in this enum is rejected with `invalid_payload`.
public enum KeyName: String, Codable, CaseIterable, Sendable {
    // Editing / navigation
    case `return` = "Return"
    case enter = "Enter"
    case escape = "Escape"
    case tab = "Tab"
    case space = "Space"
    case backspace = "Backspace"
    case forwardDelete = "Delete"
    case up = "ArrowUp"
    case down = "ArrowDown"
    case left = "ArrowLeft"
    case right = "ArrowRight"
    case home = "Home"
    case end = "End"
    case pageUp = "PageUp"
    case pageDown = "PageDown"

    // Letters
    case a = "a", b = "b", c = "c", d = "d", e = "e", f = "f", g = "g", h = "h", i = "i"
    case j = "j", k = "k", l = "l", m = "m", n = "n", o = "o", p = "p", q = "q", r = "r"
    case s = "s", t = "t", u = "u", v = "v", w = "w", x = "x", y = "y", z = "z"

    // Digits
    case d0 = "0", d1 = "1", d2 = "2", d3 = "3", d4 = "4"
    case d5 = "5", d6 = "6", d7 = "7", d8 = "8", d9 = "9"

    // Punctuation commonly used in shortcuts
    case minus = "-", equal = "=", bracketLeft = "[", bracketRight = "]"
    case slash = "/", backslash = "\\", semicolon = ";", quote = "'"
    case comma = ",", period = ".", grave = "`"

    // Function row
    case f1 = "F1", f2 = "F2", f3 = "F3", f4 = "F4", f5 = "F5", f6 = "F6"
    case f7 = "F7", f8 = "F8", f9 = "F9", f10 = "F10", f11 = "F11", f12 = "F12"
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift   = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    /// Wire names. Unknown modifier strings are rejected rather than ignored, so a client
    /// asking for something we do not understand never silently gets a *different* keystroke.
    public static func parse(_ names: [String]) throws -> KeyModifiers {
        var mods = KeyModifiers()
        for name in names {
            switch name.lowercased() {
            case "cmd", "command", "meta": mods.insert(.command)
            case "shift":                  mods.insert(.shift)
            case "alt", "option":          mods.insert(.option)
            case "ctrl", "control":        mods.insert(.control)
            case "fn", "function":         mods.insert(.function)
            default:
                throw ProtocolError.invalid("unknown modifier '\(name)'")
            }
        }
        return mods
    }

    public var wireNames: [String] {
        var out: [String] = []
        if contains(.command) { out.append("cmd") }
        if contains(.shift) { out.append("shift") }
        if contains(.option) { out.append("alt") }
        if contains(.control) { out.append("ctrl") }
        if contains(.function) { out.append("fn") }
        return out
    }
}

public enum MediaCommandName: String, Codable, CaseIterable, Sendable {
    case playPause = "play_pause"
    case next
    case previous
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case mute
    case seekForward = "seek_forward"
    case seekBack = "seek_back"
    case fullscreenToggle = "fullscreen_toggle"
    case fullscreenExit = "fullscreen_exit"
}

public enum MouseButton: String, Codable, Sendable {
    case left, right
}
