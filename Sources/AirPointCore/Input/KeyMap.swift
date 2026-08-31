import Foundation
import CoreGraphics
import RemoteKit

/// Maps the protocol's key *names* to macOS virtual keycodes.
///
/// This table is the reason the wire protocol carries names rather than keycodes: the
/// mapping is a host concern, it is exhaustively enumerable, and a client can never ask
/// for a keycode that is not in it.
///
/// The values are the ANSI virtual keycodes from `<Carbon/HIToolbox/Events.h>`. They are
/// positional, not layout-dependent, so `.a` produces whatever character the user's active
/// layout puts at the QWERTY 'a' position — which is the correct behaviour for shortcuts.
/// Literal text never goes through this table; it goes through `keyboardSetUnicodeString`.
enum KeyMap {

    static func virtualKeyCode(for key: KeyName) -> CGKeyCode? { table[key] }

    private static let table: [KeyName: CGKeyCode] = [
        .a: 0x00, .s: 0x01, .d: 0x02, .f: 0x03, .h: 0x04, .g: 0x05,
        .z: 0x06, .x: 0x07, .c: 0x08, .v: 0x09, .b: 0x0B, .q: 0x0C,
        .w: 0x0D, .e: 0x0E, .r: 0x0F, .y: 0x10, .t: 0x11,
        .d1: 0x12, .d2: 0x13, .d3: 0x14, .d4: 0x15, .d6: 0x16, .d5: 0x17,
        .equal: 0x18, .d9: 0x19, .d7: 0x1A, .minus: 0x1B, .d8: 0x1C, .d0: 0x1D,
        .bracketRight: 0x1E, .o: 0x1F, .u: 0x20, .bracketLeft: 0x21, .i: 0x22, .p: 0x23,
        .return: 0x24, .enter: 0x24, .l: 0x25, .j: 0x26, .quote: 0x27, .k: 0x28,
        .semicolon: 0x29, .backslash: 0x2A, .comma: 0x2B, .slash: 0x2C, .n: 0x2D,
        .m: 0x2E, .period: 0x2F, .tab: 0x30, .space: 0x31, .grave: 0x32,
        .backspace: 0x33, .escape: 0x35,

        .forwardDelete: 0x75, .home: 0x73, .end: 0x77,
        .pageUp: 0x74, .pageDown: 0x79,
        .left: 0x7B, .right: 0x7C, .down: 0x7D, .up: 0x7E,

        .f1: 0x7A, .f2: 0x78, .f3: 0x63, .f4: 0x76, .f5: 0x60, .f6: 0x61,
        .f7: 0x62, .f8: 0x64, .f9: 0x65, .f10: 0x6D, .f11: 0x67, .f12: 0x6F,
    ]

    static func cgFlags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift)   { flags.insert(.maskShift) }
        if modifiers.contains(.option)  { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// Every name the protocol accepts must have a keycode, or the allowlist and the
    /// executor have drifted apart. Checked once at startup so the failure is a loud
    /// log line rather than a key that silently does nothing months later.
    static func unmappedKeys() -> [KeyName] {
        KeyName.allCases.filter { table[$0] == nil }
    }
}
