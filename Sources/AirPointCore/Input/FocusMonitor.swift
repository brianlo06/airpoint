import Foundation
import ApplicationServices
import RemoteKit

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
public final class FocusMonitor {

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
    /// The element that last held focus.
    ///
    /// Tracked because reporting only when the *boolean* changes is not enough: moving from
    /// one text field to another leaves it true, so nothing is sent. In practice the first
    /// thing focused is the Terminal the daemon runs in — itself a text area — so the phone
    /// would be told once at connect and then never again when the user actually clicked
    /// into a search box.
    private var lastElement: AXUIElement?

    /// Called only when the answer changes, on `queue`.
    private let onChange: (Bool) -> Void

    /// Roles seen so far, so an unrecognised one is reported once rather than every poll.
    private var reportedRoles: Set<String> = []

    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.lastValue = nil
            self?.lastElement = nil
        }
    }

    private func poll() {
        let element = focusedElement()
        let role = element.flatMap(role(of:))
        let isTextInput = role.map(Self.textRoles.contains) ?? false

        // Debug only, so the default promise — that nothing about the host's UI is written
        // anywhere — holds. A role is a control *type*, never its contents, but it is still
        // more than the daemon needs to say out loud unless someone is debugging.
        if let role, !reportedRoles.contains(role) {
            reportedRoles.insert(role)
            Log.debug("focus: role '\(role)' \(isTextInput ? "accepts" : "does not accept") text")
        }

        let elementChanged = !sameElement(lastElement, element)
        let decision = FocusDecision.decide(previousValue: lastValue,
                                            elementChanged: elementChanged,
                                            isTextInput: isTextInput)
        lastElement = element
        lastValue = isTextInput

        guard let decision else { return }
        Log.debug("focus: text input \(decision ? "took" : "lost") focus")
        onChange(decision)
    }

    private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return CFEqual(l, r)
        default: return false
        }
    }

    private func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focusedRef = focused else { return nil }
        // CFGetTypeID rather than a force cast: a failed query can hand back something that
        // is not an AXUIElement, and crashing the daemon over a focus poll would be absurd.
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        return (focusedRef as! AXUIElement)
    }

    private func role(of element: AXUIElement) -> String? {
        var role: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard status == .success else { return nil }
        return role as? String
    }
}
