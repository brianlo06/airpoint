import Foundation
import RemoteKit
import AppKit

/// Posts hardware media-key events.
///
/// These are not ordinary keystrokes. macOS routes `NX_KEYTYPE_*` system-defined events
/// specially: the volume HUD appears, and the frontmost media session (including a browser
/// tab playing video, via the Media Session API) receives play/pause. Sending a regular
/// keycode instead would type a character into whatever field has focus.
///
/// There is no public Swift API for this, so we build the `NSEvent` by hand exactly as
/// the hardware driver does and convert it to a `CGEvent` to post.
enum MediaKeys {

    /// Subset of `NX_KEYTYPE_*` from `<IOKit/hidsystem/ev_keymap.h>`.
    enum Key: Int32 {
        case soundUp = 0
        case soundDown = 1
        case mute = 7
        case play = 16
        case next = 17
        case previous = 18
        case fast = 19
        case rewind = 20
    }

    /// `NSEvent.EventType.systemDefined` subtype for an aux control button.
    private static let auxControlButtonSubtype: Int16 = 8

    static func post(_ key: Key) {
        send(key, isDown: true)
        send(key, isDown: false)
    }

    private static func send(_ key: Key, isDown: Bool) {
        // data1 packs the key code in the high 16 bits and the state in bits 8–15.
        // The modifier flags field carries the down/up state again (0xA00 / 0xB00);
        // both are required or the event is ignored.
        let keyState: Int32 = isDown ? 0x0A : 0x0B
        let data1 = Int((key.rawValue << 16) | (keyState << 8))
        let flags: NSEvent.ModifierFlags = isDown
            ? NSEvent.ModifierFlags(rawValue: 0xA00)
            : NSEvent.ModifierFlags(rawValue: 0xB00)

        guard let event = NSEvent.otherEvent(with: .systemDefined,
                                             location: .zero,
                                             modifierFlags: flags,
                                             timestamp: 0,
                                             windowNumber: 0,
                                             context: nil,
                                             subtype: auxControlButtonSubtype,
                                             data1: data1,
                                             data2: -1) else {
            Log.warn("could not construct media key event for \(key)")
            return
        }
        guard let cgEvent = event.cgEvent else {
            Log.warn("could not convert media key event to CGEvent")
            return
        }
        cgEvent.post(tap: .cghidEventTap)
    }
}
