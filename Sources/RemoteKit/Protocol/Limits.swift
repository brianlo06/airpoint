import Foundation

/// Every hard bound the server enforces, in one place so the protocol doc,
/// the tests and the implementation cannot drift apart.
public enum Limits {
    public static let protocolVersion = 1

    /// Largest accepted WebSocket frame. Anything bigger is a protocol abuse, not a big message.
    public static let maxFrameBytes = 8 * 1024

    /// Per-message pointer delta ceiling, in pixels. Values beyond this are clamped, not rejected:
    /// a clamp keeps the cursor moving during a burst, a reject makes it stutter.
    public static let maxPointerDelta: Double = 400

    public static let maxScrollDelta: Double = 2000
    public static let maxClicks = 2
    public static let maxKeyRepeat = 10
    /// Every pad button at once. More than this is a client repeating itself.
    public static let maxPadButtons = 12
    public static let maxTextLength = 1024
    public static let maxSeekAmount: Double = 600
    public static let minSeekAmount: Double = 1

    /// Consecutive frames that are not even valid JSON, tolerated before closing.
    /// A client that cannot emit JSON is broken, not merely wrong, so this is strict.
    public static let maxMalformedFrames = 3

    /// Consecutive *rejected* frames (bad JSON, unknown type, or failed validation)
    /// tolerated before closing. More generous than the JSON limit: a client with a
    /// minor bug — an unsupported key name, say — should get told what is wrong and
    /// keep working, not be disconnected. Both counters reset on any accepted frame.
    public static let maxRejectedFrames = 20

    /// A client must authenticate this soon after connecting.
    public static let helloDeadline: TimeInterval = 5

    /// No frame at all for this long means the peer is gone.
    public static let idleTimeout: TimeInterval = 10

    /// Hard session lifetime regardless of activity.
    public static let sessionLifetime: TimeInterval = 3600

    /// A drag left open this long is a bug or a dropped phone; end it.
    public static let maxDragDuration: TimeInterval = 30

    /// Pairing code validity and lockout policy.
    ///
    /// 5 minutes, not 90 seconds. First-time pairing requires the user to tap through a
    /// certificate interstitial, grant motion permission, and approve on the Mac — a 90
    /// second window expires mid-flow almost every time, and the failure looks like a
    /// wrong code rather than a timeout. The security argument is unaffected: the code is
    /// still single-use, still rate-limited to 5 attempts, and a human still has to approve.
    public static let pairingCodeTTL: TimeInterval = 300
    public static let pairingApprovalTimeout: TimeInterval = 60
    public static let maxPairingAttempts = 5
    public static let pairingLockout: TimeInterval = 15 * 60
}
