import Foundation
import RemoteKit
import RemoteServer

/// AirPoint's meaning for the events `RemoteServer` delivers: move the macOS cursor.
///
/// Everything specific to being a *cursor remote* lives here. The server below it knows
/// about TLS, pairing, framing and validation, and nothing about `CGEvent` — which is what
/// lets a game reuse the same transport with an entirely different handler.
final class PointerHandler: RemoteSessionHandler {

    private let executor: InputExecutor
    private let dryRun: Bool
    private let focusDetection: Bool

    private let lock = NSLock()
    private var focusMonitors: [UUID: FocusMonitor] = [:]

    init(executor: InputExecutor, dryRun: Bool, focusDetection: Bool) {
        self.executor = executor
        self.dryRun = dryRun
        self.focusDetection = focusDetection
    }

    // MARK: - Capabilities

    func features(for session: RemoteSession) -> [String] {
        var features = ["pointer", "scroll", "keyboard", "media", "drag"]
        if dryRun { features.append("dry-run") }
        return features
    }

    func displays(for session: RemoteSession) -> [DisplayInfo] {
        executor.displays()
    }

    func isReady(for session: RemoteSession) -> Bool {
        // In a dry run the events are recorded rather than posted, so the Accessibility
        // permission is irrelevant and the session should behave as though it were granted.
        dryRun || executor.hasPermission
    }

    func permissions(for session: RemoteSession) -> [String: Bool] {
        // `accessibility` is part of the published protocol and the controller reads it by
        // name to explain why the cursor is not moving.
        ["accessibility": dryRun || executor.hasPermission]
    }

    // MARK: - Lifecycle

    func sessionDidBegin(_ session: RemoteSession) {
        if !executor.hasPermission && !dryRun {
            Log.warn("connected, but Accessibility permission is missing — input will not work")
        }
        guard focusDetection, executor.hasPermission, !dryRun else {
            Log.debug("focus detection unavailable (accessibility=\(executor.hasPermission), dryRun=\(dryRun))")
            return
        }
        // Reading which control has focus is a macOS concern, so it is driven from here
        // rather than from the session layer. The server only carries the result.
        let monitor = FocusMonitor { [weak session] isTextInput in
            session?.send(focus: FocusPayload(textInput: isTextInput))
        }
        monitor.start()
        lock.lock()
        focusMonitors[session.id] = monitor
        lock.unlock()
        Log.debug("focus detection started")
    }

    func sessionDidEnd(_ session: RemoteSession) {
        lock.lock()
        let monitor = focusMonitors.removeValue(forKey: session.id)
        lock.unlock()
        monitor?.stop()
        // Whoever held the pointer may have left a button or modifier down.
        executor.releaseAll()
    }

    // MARK: - Events

    func handle(_ event: ClientEvent, from session: RemoteSession) {
        switch event {
        case .pointerMove(let move):
            executor.moveCursor(dx: move.dx, dy: move.dy)

        case .leftClick(let click):
            executor.click(button: .left, count: click.clicks)

        case .rightClick(let click):
            executor.click(button: .right, count: click.clicks)

        case .dragStart(let drag):
            executor.beginDrag(button: drag.button)

        case .dragEnd(let drag):
            executor.endDrag(button: drag.button)

        case .scroll(let scroll):
            executor.scroll(dx: scroll.dx, dy: scroll.dy, unit: scroll.unit, isMomentum: scroll.momentum)

        case .keyPress(let key):
            executor.pressKey(key.key, modifiers: key.modifiers, repeatCount: key.repeatCount)

        case .textInput(let text):
            executor.typeText(text.text)

        case .mediaCommand(let media):
            executor.mediaCommand(media.command, amount: media.amount)

        case .recenter(let recenter):
            // Recentring is a client-side operation; the host's only job is the optional
            // courtesy of parking the cursor where the user is about to point.
            if recenter.toCenter { executor.centerCursorOnActiveDisplay() }

        case .calibration, .hello, .ping, .disconnect:
            // Handled by the session layer; nothing for a cursor to do.
            break
        }
    }
}
