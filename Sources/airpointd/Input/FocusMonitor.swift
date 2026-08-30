import Foundation
import ApplicationServices

/// Reports whether the Mac's focused UI element accepts typed text.
///
/// This exists so the phone can raise its keyboard the moment you click into a search box,
/// instead of making you find the Keys tab by hand.
///
/// **What it reads, precisely:** the `AXRole` string of the system-wide focused element —
/// "AXTextField", "AXTextArea", and so on. That is all. It never reads the element's value,
/// its title, its contents, the window, or anything about what is on screen, and the only
/// thing that ever leaves this file is a single boolean. Nothing is stored and nothing is
/// logged. The role of the focused control is the minimum needed to answer "should the
/// keyboard come up", and deliberately nothing more is asked for.
///
/// It uses the Accessibility permission the daemon already requires to post events, and can
/// be turned off entirely with `--no-focus-detection`.
final class FocusMonitor {

    /// Roles that accept typed text. Web text inputs in Safari and Chrome report
    /// AXTextField or AXTextArea, so this covers browser forms as well as native apps.
    private static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox",
    ]

    /// How often the focused element is sampled. There is no notification for
    /// system-wide focus without observing every application, which would mean far broader
    /// access than this feature justifies. 4 Hz is imperceptible to a user and costs
    /// almost nothing.
    private static let pollInterval: TimeInterval = 0.25

    private let systemWide = AXUIElementCreateSystemWide()
    private let queue = DispatchQueue(label: "com.airpoint.focus")
    private var timer: DispatchSourceTimer?
    private var lastValue: Bool?

    /// Called only when the answer changes, on `queue`.
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.lastValue = nil
        }
    }

    private func poll() {
        let isTextInput = currentRole().map(Self.textRoles.contains) ?? false
        guard isTextInput != lastValue else { return }
        lastValue = isTextInput
        onChange(isTextInput)
    }

    /// The focused element's role, or nil if there is no focused element or the query fails.
    private func currentRole() -> String? {
        var focused: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusStatus == .success, let focusedRef = focused else { return nil }

        // CFGetTypeID rather than a force cast: a failed query can hand back something that
        // is not an AXUIElement, and crashing the daemon over a focus poll would be absurd.
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement

        var role: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &role)
        guard roleStatus == .success else { return nil }
        return role as? String
    }
}
