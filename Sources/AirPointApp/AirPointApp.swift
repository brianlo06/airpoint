import SwiftUI
import AppKit

/// A menu-bar agent: no Dock icon, no window, always one click away.
///
/// The same server, handler and controller as `airpointd`. What changes is that approval
/// happens in a sheet instead of on stdin, the pairing code and QR are on screen, and the
/// Accessibility permission is explained where it is needed rather than in a README.
@main
struct AirPointApp: App {
    @StateObject private var model = AppModel()

    init() {
        // LSUIElement equivalent, set in code because a SwiftPM executable has no Info.plist.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // The icon changes *shape*, not only colour: a colour-only indicator is
            // invisible to a good fraction of people and unreadable at a glance to everyone.
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        switch model.status {
        case .connected: return "dot.radiowaves.left.and.right"
        case .listening: return model.hasAccessibility ? "cursorarrow.rays" : "exclamationmark.triangle"
        case .starting: return "ellipsis.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "cursorarrow"
        }
    }
}
