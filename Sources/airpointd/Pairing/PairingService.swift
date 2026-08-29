import Foundation
import RemoteKit

/// How the user is asked to approve a new device.
///
/// Abstracted so the CLI daemon can prompt on the terminal today and the menu-bar app can
/// show a sheet in Phase 4 without any change to the pairing logic.
protocol PairingApprover: AnyObject {
    func requestApproval(deviceName: String, peer: String,
                         completion: @escaping (PairingDecision) -> Void)
}

enum PairingDecision {
    case approve
    case approveAndTrust
    case deny
}

/// Owns the pairing lifecycle: the current code, its expiry, verification, lockout,
/// and the human approval step.
///
/// The security property being enforced is simple to state and worth stating: **no device
/// ever gets control without a person on this machine having said yes**, unless that person
/// previously chose to trust that specific device.
final class PairingService {

    private let queue = DispatchQueue(label: "com.airpoint.pairing")
    private let trustStore: TrustStore
    private let attempts = AttemptTracker()
    private weak var approver: PairingApprover?

    private var secret: PairingSecret
    /// Set when a code has been consumed by a successful pairing, so it cannot be reused
    /// by a second device that also observed the QR.
    private var consumed = false

    init(trustStore: TrustStore, approver: PairingApprover?) {
        self.trustStore = trustStore
        self.approver = approver
        self.secret = PairingSecret()
    }

    enum Outcome {
        case paired(deviceName: String, trusted: Bool)
        case resumed(device: TrustedDevice)
        case rejected(ProtocolError)
    }

    /// The live pairing secret, regenerated when expired or already used.
    func currentSecret() -> PairingSecret {
        queue.sync {
            if consumed || secret.isExpired() {
                secret = PairingSecret()
                consumed = false
                Log.debug("issued a fresh pairing code")
            }
            return secret
        }
    }

    /// Forces a new code, e.g. when the user asks for one in the UI.
    @discardableResult
    func rotateSecret() -> PairingSecret {
        queue.sync {
            secret = PairingSecret()
            consumed = false
            return secret
        }
    }

    func remainingCodeSeconds() -> Int {
        queue.sync { consumed ? 0 : secret.remainingSeconds() }
    }

    /// Authenticates a `hello` and, when required, asks the user.
    func authenticate(hello: HelloPayload, nonce: Data, peer: String,
                      completion: @escaping (Outcome) -> Void) {
        let now = Date().timeIntervalSince1970

        if attempts.isLocked(peer, now: now) {
            let wait = attempts.remainingLockoutMs(peer, now: now)
            Log.warn("pairing attempt from \(peer) refused: locked out for \(wait / 1000)s")
            completion(.rejected(ProtocolError(.tooManyAttempts,
                                               "too many failed attempts; try again later",
                                               retryAfterMs: wait)))
            return
        }

        guard let proof = Data(base64Encoded: hello.auth.proof) else {
            completion(.rejected(ProtocolError.invalid("auth.proof is not valid base64")))
            return
        }

        switch hello.auth.mode {
        case .resume:
            resume(hello: hello, proof: proof, nonce: nonce, peer: peer, now: now, completion: completion)
        case .code:
            pair(hello: hello, proof: proof, nonce: nonce, peer: peer, now: now, completion: completion)
        }
    }

    // MARK: - Resume

    private func resume(hello: HelloPayload, proof: Data, nonce: Data, peer: String,
                        now: TimeInterval, completion: @escaping (Outcome) -> Void) {
        guard let device = trustStore.device(withId: hello.deviceId) else {
            // Deliberately the same error as a bad signature: an attacker should not be able
            // to enumerate which device IDs this Mac trusts.
            attempts.recordFailure(peer, now: now)
            completion(.rejected(ProtocolError(.pairRejected, "this device is not paired")))
            return
        }
        guard trustStore.verifyResumeSignature(device: device, nonce: nonce, signature: proof) else {
            attempts.recordFailure(peer, now: now)
            Log.warn("bad resume signature for \(Log.short(hello.deviceId)) from \(peer)")
            completion(.rejected(ProtocolError(.pairRejected, "this device is not paired")))
            return
        }
        attempts.recordSuccess(peer)
        trustStore.recordSeen(device)
        Log.info("trusted device reconnected: \(device.deviceName) from \(peer)")
        completion(.resumed(device: device))
    }

    // MARK: - First pairing

    private func pair(hello: HelloPayload, proof: Data, nonce: Data, peer: String,
                      now: TimeInterval, completion: @escaping (Outcome) -> Void) {
        let active = currentSecret()
        guard !active.isExpired() else {
            completion(.rejected(ProtocolError(.pairTimeout, "the pairing code expired; get a new one")))
            return
        }
        guard let channel = active.verify(proof: proof, nonce: nonce, deviceId: hello.deviceId) else {
            attempts.recordFailure(peer, now: now)
            Log.warn("bad pairing proof from \(peer) (device \(Log.short(hello.deviceId)))")
            completion(.rejected(ProtocolError(.pairRejected, "incorrect pairing code")))
            return
        }
        attempts.recordSuccess(peer)
        Log.info("valid pairing proof via \(channel == .qr ? "QR" : "typed code") from \(peer)")

        guard let approver else {
            completion(.rejected(ProtocolError(.pairRejected, "no approval interface available")))
            return
        }

        // The approval prompt is the security boundary; everything before it only proves the
        // device saw the code.
        // Both the timeout and the user's answer race to settle this request; whichever
        // arrives first wins and the other is dropped.
        var settled = false
        let settle: (Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            let alreadySettled: Bool = self.queue.sync {
                if settled { return true }
                settled = true
                return false
            }
            guard !alreadySettled else { return }
            completion(outcome)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + Limits.pairingApprovalTimeout) {
            settle(.rejected(ProtocolError(.pairTimeout, "the pairing request was not approved in time")))
        }

        approver.requestApproval(deviceName: hello.deviceName, peer: peer) { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .deny:
                Log.info("user denied pairing for '\(hello.deviceName)'")
                settle(.rejected(ProtocolError(.pairRejected, "the pairing request was declined")))
            case .approve, .approveAndTrust:
                self.queue.sync { self.consumed = true }
                var trusted = false
                if case .approveAndTrust = decision {
                    if let publicKey = hello.auth.publicKey {
                        trusted = self.trustStore.trust(deviceId: hello.deviceId,
                                                        deviceName: hello.deviceName,
                                                        publicKey: publicKey)
                        if !trusted { Log.warn("could not persist trust for '\(hello.deviceName)'") }
                    } else {
                        Log.warn("'\(hello.deviceName)' asked to be trusted but sent no public key")
                    }
                }
                Log.info("user approved pairing for '\(hello.deviceName)'\(trusted ? " (remembered)" : "")")
                settle(.paired(deviceName: hello.deviceName, trusted: trusted))
            }
        }
    }
}

/// Terminal approval prompt for the CLI daemon.
///
/// Reads from stdin on a dedicated thread so the listener's queues are never blocked by a
/// human deciding.
final class ConsoleApprover: PairingApprover {

    private let autoApprove: Bool
    private let queue = DispatchQueue(label: "com.airpoint.approval")

    init(autoApprove: Bool) { self.autoApprove = autoApprove }

    /// Truncates and pads to the fixed box width so a long device name cannot break the
    /// layout — or, worse, use padding to push the warning text off screen.
    private static func field(_ value: String, width: Int = 46) -> String {
        let truncated = value.count > width ? String(value.prefix(width - 1)) + "…" : value
        return truncated.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    func requestApproval(deviceName: String, peer: String,
                         completion: @escaping (PairingDecision) -> Void) {
        if autoApprove {
            Log.warn("auto-approving '\(deviceName)' from \(peer) (--auto-approve)")
            completion(.approve)
            return
        }
        queue.async {
            let prompt = """

            ┌──────────────────────────────────────────────────────────┐
            │  PAIRING REQUEST                                         │
            │                                                          │
            │  Device:  \(Self.field(deviceName))│
            │  Address: \(Self.field(peer))│
            │                                                          │
            │  This device will be able to move the cursor, click,     │
            │  and type on this Mac.                                   │
            └──────────────────────────────────────────────────────────┘
            Approve?  [y] yes once   [t] yes and remember   [n] no  >\u{20}
            """
            FileHandle.standardError.write(Data(prompt.utf8))

            guard let line = readLine(strippingNewline: true)?.lowercased() else {
                completion(.deny)
                return
            }
            switch line {
            case "y", "yes":            completion(.approve)
            case "t", "trust":          completion(.approveAndTrust)
            default:                    completion(.deny)
            }
        }
    }
}
