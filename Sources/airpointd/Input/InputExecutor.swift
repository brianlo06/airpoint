import Foundation
import RemoteKit

/// Everything the daemon is allowed to do to the host machine.
///
/// The protocol exists so that (a) tests can assert on a recorded command stream without
/// moving a real cursor, and (b) a Windows `SendInput` backend can be added later without
/// touching the session or protocol layers. It is intentionally small: the whole point of
/// putting the motion maths on the phone is that this side stays a thin, auditable surface.
public protocol InputExecutor: AnyObject {
    /// True when the OS will actually accept synthesised events.
    var hasPermission: Bool { get }

    func moveCursor(dx: Double, dy: Double)
    func click(button: MouseButton, count: Int)
    func beginDrag(button: MouseButton)
    func endDrag(button: MouseButton)
    func scroll(dx: Double, dy: Double, unit: ScrollPayload.Unit, isMomentum: Bool)
    func pressKey(_ key: KeyName, modifiers: KeyModifiers, repeatCount: Int)
    func typeText(_ text: String)
    func mediaCommand(_ command: MediaCommandName, amount: Double?)
    func centerCursorOnActiveDisplay()

    /// Releases every button and modifier this executor may have left held.
    /// Called on every session teardown and on panic — a stuck mouse-down or a stuck
    /// Command key is the worst failure mode this application has.
    func releaseAll()

    var isDragging: Bool { get }
    func displays() -> [DisplayInfo]
    func activeDisplayID() -> Int
}

/// Records commands instead of executing them. Used by `--dry-run` and by tests.
public final class RecordingExecutor: InputExecutor {
    public enum Command: Equatable {
        case move(dx: Double, dy: Double)
        case click(button: MouseButton, count: Int)
        case beginDrag(MouseButton)
        case endDrag(MouseButton)
        case scroll(dx: Double, dy: Double)
        case key(KeyName, KeyModifiers.RawValue, Int)
        case text(length: Int)
        case media(MediaCommandName, Double?)
        case center
        case releaseAll
    }

    public private(set) var commands: [Command] = []
    public private(set) var isDragging = false
    public var hasPermission: Bool { true }

    public init() {}

    public func moveCursor(dx: Double, dy: Double) { commands.append(.move(dx: dx, dy: dy)) }
    public func click(button: MouseButton, count: Int) { commands.append(.click(button: button, count: count)) }
    public func beginDrag(button: MouseButton) { isDragging = true; commands.append(.beginDrag(button)) }
    public func endDrag(button: MouseButton) { isDragging = false; commands.append(.endDrag(button)) }
    public func scroll(dx: Double, dy: Double, unit: ScrollPayload.Unit, isMomentum: Bool) {
        commands.append(.scroll(dx: dx, dy: dy))
    }
    public func pressKey(_ key: KeyName, modifiers: KeyModifiers, repeatCount: Int) {
        commands.append(.key(key, modifiers.rawValue, repeatCount))
    }
    /// Records only the length. The text itself is never retained, so a dry run cannot
    /// become an accidental keylog.
    public func typeText(_ text: String) { commands.append(.text(length: text.count)) }
    public func mediaCommand(_ command: MediaCommandName, amount: Double?) {
        commands.append(.media(command, amount))
    }
    public func centerCursorOnActiveDisplay() { commands.append(.center) }
    public func releaseAll() { isDragging = false; commands.append(.releaseAll) }
    public func displays() -> [DisplayInfo] {
        [DisplayInfo(id: 1, w: 1920, h: 1080, scale: 2, main: true)]
    }
    public func activeDisplayID() -> Int { 1 }
}
