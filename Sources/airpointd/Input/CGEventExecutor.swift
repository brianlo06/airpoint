import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import RemoteKit

/// The only file in the project that synthesises real input events.
///
/// Everything above it deals in validated, bounded values; everything below it is the OS.
/// Keeping that boundary in one file is what makes the security story reviewable.
///
/// Requires the Accessibility permission (System Settings ▸ Privacy & Security ▸
/// Accessibility). Without it `CGEvent.post` silently does nothing, which is why
/// `hasPermission` is checked and surfaced to the phone rather than being assumed.
final class CGEventExecutor: InputExecutor {

    private let source: CGEventSource?
    private let queue = DispatchQueue(label: "com.airpoint.input", qos: .userInteractive)

    private var dragging: MouseButton?
    private var dragStartedAt: Date?

    /// Where we believe the cursor is, in global display coordinates.
    ///
    /// Deltas are integrated here rather than against a fresh read of the OS cursor position
    /// on every frame. Reading it back per frame looks correct and is not: a posted event
    /// reaches the window server asynchronously, so a burst of frames processed back to back
    /// all read the *same* pre-move position and each one computes `stale + delta`. The
    /// cursor then jitters around a fixed point instead of travelling, which is
    /// indistinguishable from "the cursor does not move". `--selftest` hid this by sleeping
    /// 6 ms between moves, which is long enough for the read-back to settle.
    ///
    /// Fractional pixels accumulate here too, so slow movement is not lost to rounding.
    private var virtualPosition: CGPoint?
    /// When the last synthetic move happened, so a physical mouse nudge is not fought over.
    private var lastSyntheticMoveAt = Date.distantPast
    /// After this long without synthetic movement, trust the OS position again — the user
    /// may have picked up a real mouse, or another app may have warped the cursor.
    private static let resyncInterval: TimeInterval = 0.5

    init() {
        // .hidSystemState posts as though the events came from the hardware, which is what
        // makes them reach apps that filter on event source, including full-screen video players.
        source = CGEventSource(stateID: .hidSystemState)
        if source == nil {
            Log.error("could not create a CGEventSource; input will not work")
        }
        let unmapped = KeyMap.unmappedKeys()
        if !unmapped.isEmpty {
            Log.error("key allowlist has \(unmapped.count) names with no keycode: \(unmapped.map(\.rawValue).joined(separator: ","))")
        }
    }

    var hasPermission: Bool { AXIsProcessTrusted() }

    var isDragging: Bool { queue.sync { dragging != nil } }

    /// Prompts for Accessibility once, on an explicit user action only.
    @discardableResult
    func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Pointer

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func moveCursor(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let geometry = DisplayGeometry.cachedCurrent()
            let now = Date()

            // Re-seed from the OS only when we have not been driving the cursor recently.
            var origin: CGPoint
            if let known = self.virtualPosition,
               now.timeIntervalSince(self.lastSyntheticMoveAt) < Self.resyncInterval {
                origin = known
            } else {
                origin = self.currentLocation()
            }
            self.lastSyntheticMoveAt = now

            let target = CGPoint(x: origin.x + dx, y: origin.y + dy)
            let clamped = geometry.clamp(target)
            self.virtualPosition = clamped

            // The event itself needs integer pixels; the fractional part stays in
            // virtualPosition so slow movement accumulates instead of rounding to nothing.
            let posted = CGPoint(x: clamped.x.rounded(), y: clamped.y.rounded())

            let type: CGEventType
            let button: CGMouseButton
            switch self.dragging {
            case .left:  type = .leftMouseDragged;  button = .left
            case .right: type = .rightMouseDragged; button = .right
            case nil:    type = .mouseMoved;        button = .left
            }

            guard let event = CGEvent(mouseEventSource: self.source, mouseType: type,
                                      mouseCursorPosition: posted, mouseButton: button) else { return }
            // Apps that read deltas (games, some canvas apps) ignore absolute position,
            // so set both.
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((posted.x - origin.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((posted.y - origin.y).rounded()))
            event.post(tap: .cghidEventTap)

            self.enforceDragTimeout()
        }
    }

    func centerCursorOnActiveDisplay() {
        queue.async { [weak self] in
            guard let self else { return }
            let geometry = DisplayGeometry.current()
            let current = self.currentLocation()
            let screen = geometry.screen(containing: current) ?? geometry.mainScreen
            guard let screen else { return }
            let center = geometry.center(of: screen)
            self.virtualPosition = center
            self.lastSyntheticMoveAt = Date()
            guard let event = CGEvent(mouseEventSource: self.source, mouseType: .mouseMoved,
                                      mouseCursorPosition: center, mouseButton: .left) else { return }
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Buttons

    private func mouseTypes(for button: MouseButton) -> (down: CGEventType, up: CGEventType, cg: CGMouseButton) {
        switch button {
        case .left:  return (.leftMouseDown, .leftMouseUp, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .right)
        }
    }

    func click(button: MouseButton, count: Int) {
        let clicks = min(max(count, 1), 2)
        queue.async { [weak self] in
            guard let self else { return }
            let location = self.currentLocation()
            let types = self.mouseTypes(for: button)
            for click in 1...clicks {
                for type in [types.down, types.up] {
                    guard let event = CGEvent(mouseEventSource: self.source, mouseType: type,
                                              mouseCursorPosition: location, mouseButton: types.cg) else { continue }
                    // Without clickState, two rapid clicks are two single clicks and never
                    // register as a double-click in AppKit or the browser.
                    event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                    event.post(tap: .cghidEventTap)
                }
            }
        }
    }

    func beginDrag(button: MouseButton) {
        queue.async { [weak self] in
            guard let self, self.dragging == nil else { return }
            let location = self.currentLocation()
            let types = self.mouseTypes(for: button)
            guard let event = CGEvent(mouseEventSource: self.source, mouseType: types.down,
                                      mouseCursorPosition: location, mouseButton: types.cg) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
            self.dragging = button
            self.dragStartedAt = Date()
            Log.debug("drag started (\(button.rawValue))")
        }
    }

    func endDrag(button: MouseButton) {
        queue.async { [weak self] in self?.endDragLocked() }
    }

    private func endDragLocked() {
        guard let button = dragging else { return }
        let location = currentLocation()
        let types = mouseTypes(for: button)
        if let event = CGEvent(mouseEventSource: source, mouseType: types.up,
                               mouseCursorPosition: location, mouseButton: types.cg) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
        dragging = nil
        dragStartedAt = nil
        Log.debug("drag ended")
    }

    /// A drag left open past the limit is a dropped phone or a lost packet, not intent.
    private func enforceDragTimeout() {
        guard let started = dragStartedAt,
              Date().timeIntervalSince(started) > Limits.maxDragDuration else { return }
        Log.warn("drag exceeded \(Int(Limits.maxDragDuration))s — releasing")
        endDragLocked()
    }

    // MARK: - Scroll

    func scroll(dx: Double, dy: Double, unit: ScrollPayload.Unit, isMomentum: Bool) {
        guard dx.isFinite, dy.isFinite else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let cgUnit: CGScrollEventUnit = unit == .px ? .pixel : .line
            guard let event = CGEvent(scrollWheelEvent2Source: self.source, units: cgUnit,
                                      wheelCount: 2,
                                      wheel1: Int32(clamping: Int(dy)),
                                      wheel2: Int32(clamping: Int(dx)),
                                      wheel3: 0) else { return }
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard

    func pressKey(_ key: KeyName, modifiers: KeyModifiers, repeatCount: Int) {
        guard let code = KeyMap.virtualKeyCode(for: key) else {
            Log.warn("no keycode for allowlisted key '\(key.rawValue)' — check KeyMap")
            return
        }
        let flags = KeyMap.cgFlags(for: modifiers)
        let count = min(max(repeatCount, 1), Limits.maxKeyRepeat)
        queue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<count {
                for isDown in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: self.source,
                                              virtualKey: code, keyDown: isDown) else { continue }
                    event.flags = flags
                    event.post(tap: .cghidEventTap)
                }
            }
        }
    }

    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        // Chunked because a single event's Unicode string buffer is bounded, and because
        // very long bursts starve the target app's event loop.
        let units = Array(text.utf16)
        queue.async { [weak self] in
            guard let self else { return }
            for start in stride(from: 0, to: units.count, by: 20) {
                let chunk = Array(units[start..<min(start + 20, units.count)])
                for isDown in [true, false] {
                    // virtualKey 0 with an attached Unicode string is the documented way to
                    // type arbitrary text without needing a keycode for every character —
                    // it works regardless of the user's keyboard layout.
                    guard let event = CGEvent(keyboardEventSource: self.source,
                                              virtualKey: 0, keyDown: isDown) else { continue }
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event.post(tap: .cghidEventTap)
                }
            }
        }
        Log.debug("typed \(Log.redacted(text))")
    }

    // MARK: - Media

    func mediaCommand(_ command: MediaCommandName, amount: Double?) {
        switch command {
        case .playPause:    MediaKeys.post(.play)
        case .next:         MediaKeys.post(.next)
        case .previous:     MediaKeys.post(.previous)
        case .volumeUp:     MediaKeys.post(.soundUp)
        case .volumeDown:   MediaKeys.post(.soundDown)
        case .mute:         MediaKeys.post(.mute)

        // Seeking has no system-wide key. Browsers map arrow keys to a seek in the focused
        // player, but the interval is site-specific (YouTube 5 s, Netflix 10 s, others vary),
        // so we approximate with repeats and document the imprecision rather than pretending
        // to a accuracy we do not have. Per-site profiles are Phase 5.
        case .seekForward:
            pressKey(.right, modifiers: [], repeatCount: Self.seekPresses(for: amount))
        case .seekBack:
            pressKey(.left, modifiers: [], repeatCount: Self.seekPresses(for: amount))

        // 'f' is the fullscreen toggle in every major browser video player. Escape is the
        // universal exit, and unlike 'f' it also works when the player has lost focus.
        case .fullscreenToggle:
            pressKey(.f, modifiers: [], repeatCount: 1)
        case .fullscreenExit:
            pressKey(.escape, modifiers: [], repeatCount: 1)
        }
    }

    /// Assumes a 5-second-per-press player, capped so a bad `amount` cannot spam 120 keystrokes.
    static func seekPresses(for amount: Double?) -> Int {
        guard let amount, amount.isFinite, amount > 0 else { return 1 }
        return min(max(Int((amount / 5).rounded()), 1), 12)
    }

    // MARK: - Teardown

    func releaseAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.endDragLocked()
            self.virtualPosition = nil

            // Release every modifier by posting a flags-cleared event. A stuck Command key
            // after a dropped connection makes the machine feel broken, and the user has no
            // way to know why.
            if let event = CGEvent(keyboardEventSource: self.source, virtualKey: 0, keyDown: false) {
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
            Log.info("released all held buttons and modifiers")
        }
    }

    // MARK: - Displays

    func displays() -> [DisplayInfo] {
        let geometry = DisplayGeometry.current()
        return geometry.screens.enumerated().map { index, screen in
            DisplayInfo(id: index + 1,
                        w: Int(screen.frame.width),
                        h: Int(screen.frame.height),
                        scale: screen.scale,
                        main: screen.isMain)
        }
    }

    func activeDisplayID() -> Int {
        let geometry = DisplayGeometry.current()
        let location = currentLocation()
        guard let index = geometry.screens.firstIndex(where: { $0.frame.contains(location) }) else { return 1 }
        return index + 1
    }
}
