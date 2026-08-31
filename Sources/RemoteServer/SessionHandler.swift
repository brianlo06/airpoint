import Foundation
import RemoteKit

/// What a host application does with the events a paired phone sends.
///
/// This is the seam that makes the server reusable. Before it existed, the session layer
/// called an `InputExecutor` directly, so the only thing this code could ever do was move a
/// macOS cursor — the transport, pairing, TLS and validation were all welded to one
/// application. A handler protocol costs nothing here and lets an entirely different
/// program (a game, a presentation remote, a robot) reuse everything above it.
///
/// Implementations are called on an arbitrary queue and must be safe to call concurrently
/// from multiple sessions.
public protocol RemoteSessionHandler: AnyObject {

    /// Advertised in `welcome`, so a client can adapt its UI to what the host supports.
    func features(for session: RemoteSession) -> [String]

    /// Reported in `welcome` and used by clients to size their coordinate space.
    func displays(for session: RemoteSession) -> [DisplayInfo]

    /// Whether the host can act on events right now.
    ///
    /// A false answer is reported to the phone as `permission_denied` rather than being
    /// swallowed, because a remote that silently does nothing is indistinguishable from a
    /// broken one. AirPoint answers with the Accessibility permission; a game answers with
    /// whether a round is running.
    func isReady(for session: RemoteSession) -> Bool

    /// Reported in `welcome` so a client can explain a degraded state precisely.
    ///
    /// Host-defined, because "what might not be granted" differs per application: AirPoint
    /// reports `accessibility`, a game might report `roundInProgress`. The default supplies
    /// the conventional `ready` key so a host that has nothing to add can ignore this.
    func permissions(for session: RemoteSession) -> [String: Bool]

    /// A validated, rate-limited event. Never called before the session is authenticated.
    func handle(_ event: ClientEvent, from session: RemoteSession)

    func sessionDidBegin(_ session: RemoteSession)
    func sessionDidEnd(_ session: RemoteSession)
}

public extension RemoteSessionHandler {
    func permissions(for session: RemoteSession) -> [String: Bool] {
        ["ready": isReady(for: session)]
    }
    func sessionDidBegin(_ session: RemoteSession) {}
    func sessionDidEnd(_ session: RemoteSession) {}
}

/// A live, authenticated connection, as seen by the host application.
///
/// Deliberately narrow: a handler can identify the session and send it a status or an error,
/// and nothing else. It cannot reach into the transport.
public protocol RemoteSession: AnyObject {
    /// Stable for the lifetime of the connection. Distinguishes players.
    var id: UUID { get }
    /// As the device reported it, already sanitised for display.
    var deviceName: String? { get }
    /// The peer address, for logging and rate limiting.
    var peer: String { get }

    func send(error: ProtocolError)
    func send(status: StatusPayload)
    /// Tells the client whether the host's focused control accepts typed text, so the phone
    /// can offer its keyboard. Hosts with no such notion simply never call it.
    func send(focus: FocusPayload)
    /// Asks the client for a short haptic or audible cue. Best-effort and fire-and-forget:
    /// a client that cannot vibrate simply does not.
    func send(cue: CuePayload)
}
