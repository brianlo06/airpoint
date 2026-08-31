import Foundation
import RemoteKit
import CoreGraphics

/// Multi-display cursor clamping.
///
/// `CGEvent` uses a single global coordinate space with a top-left origin spanning every
/// attached display. The union of the display rectangles is not necessarily itself a
/// rectangle — two monitors of different heights, or offset vertically, leave L-shaped
/// gaps. Clamping naively to the bounding box therefore lets the cursor land in a hole
/// where no display exists, which on macOS means it vanishes until you move it back out.
///
/// So: if the target point is inside any display, use it. Otherwise project it to the
/// nearest point on the nearest display.
struct DisplayGeometry {

    struct Screen {
        let id: CGDirectDisplayID
        let frame: CGRect
        let isMain: Bool
        let scale: Double
    }

    private(set) var screens: [Screen]

    init(screens: [Screen]) { self.screens = screens }

    /// Cached because this runs on every pointer frame and `CGDisplayCopyDisplayMode` is
    /// expensive enough that calling it at 60 Hz shows up as input latency. Displays change
    /// rarely; a short TTL keeps hot-plug working without paying the cost per frame.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (geometry: DisplayGeometry, at: Date)?
    private static let cacheTTL: TimeInterval = 2

    static func cachedCurrent() -> DisplayGeometry {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < cacheTTL {
            return cached.geometry
        }
        let fresh = current()
        cached = (fresh, Date())
        return fresh
    }

    static func current() -> DisplayGeometry {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            // No displays reported (headless, or a transient state during wake).
            // Fall back to a single unit screen so callers never divide by zero.
            return DisplayGeometry(screens: [
                Screen(id: 0, frame: CGRect(x: 0, y: 0, width: 1, height: 1), isMain: true, scale: 1)
            ])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return DisplayGeometry(screens: [])
        }
        let main = CGMainDisplayID()
        let screens = ids.map { id -> Screen in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = mode.map { Double($0.pixelWidth) / max(Double($0.width), 1) } ?? 1
            return Screen(id: id, frame: bounds, isMain: id == main, scale: scale)
        }
        return DisplayGeometry(screens: screens)
    }

    /// Constrains a point to somewhere the cursor can actually exist.
    func clamp(_ point: CGPoint) -> CGPoint {
        guard !screens.isEmpty else { return point }
        if screens.contains(where: { $0.frame.contains(point) }) { return point }

        var best = point
        var bestDistance = Double.infinity
        for screen in screens {
            // Inset by 1 px: a point exactly on the far edge belongs to the next display,
            // which would let the cursor oscillate between two screens at the seam.
            let maxX = screen.frame.maxX - 1
            let maxY = screen.frame.maxY - 1
            let candidate = CGPoint(x: min(max(point.x, screen.frame.minX), maxX),
                                    y: min(max(point.y, screen.frame.minY), maxY))
            let dx = candidate.x - point.x
            let dy = candidate.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    func screen(containing point: CGPoint) -> Screen? {
        screens.first { $0.frame.contains(point) }
    }

    func center(of screen: Screen) -> CGPoint {
        CGPoint(x: screen.frame.midX, y: screen.frame.midY)
    }

    var mainScreen: Screen? { screens.first(where: \.isMain) ?? screens.first }
}
