import Foundation
import CryptoKit
import Security

/// One pairing attempt's shared secret and its human-readable form.
///
/// Two channels carry it:
///  - **QR** carries the full 128-bit secret plus the server certificate's SPKI fingerprint.
///    The optical channel is out-of-band, so putting the secret in it is sound, and the pin
///    defeats an active MITM.
///  - **Typed code** carries only the 6 digits, so it is weaker (no pin). The UI says so.
public struct PairingSecret: Sendable {
    /// 16 random bytes. The authoritative secret.
    public let secret: Data
    /// 6 digits derived from `secret`, for the typed-code path.
    public let displayCode: String
    public let createdAt: Date
    public let ttl: TimeInterval

    public init(ttl: TimeInterval = Limits.pairingCodeTTL, now: Date = Date()) {
        var bytes = Data(count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        precondition(status == errSecSuccess, "secure random unavailable; refusing to generate a weak pairing secret")
        self.secret = bytes
        // Derive the digits from the secret rather than generating them separately, so the
        // two channels always describe the same pairing attempt.
        let digest = SHA256.hash(data: bytes)
        let value = digest.withUnsafeBytes { $0.load(as: UInt32.self) } % 1_000_000
        self.displayCode = String(format: "%06u", value)
        self.createdAt = now
        self.ttl = ttl
    }

    public func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > ttl
    }

    public func remainingSeconds(now: Date = Date()) -> Int {
        max(0, Int(ttl - now.timeIntervalSince(createdAt)))
    }

    /// The key a client proves knowledge of. QR clients hold `secret`; typed-code clients
    /// hold only the digits, so their key is the UTF-8 of the digits.
    public enum Channel: Sendable { case qr, typedCode }

    public func key(for channel: Channel) -> Data {
        switch channel {
        case .qr: return secret
        case .typedCode: return Data(displayCode.utf8)
        }
    }

    /// proof = HMAC-SHA256(key, nonce ‖ deviceId)
    public func expectedProof(nonce: Data, deviceId: String, channel: Channel) -> Data {
        var message = nonce
        message.append(Data(deviceId.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key(for: channel)))
        return Data(mac)
    }

    /// Accepts either channel's proof. Comparison is constant-time via CryptoKit's
    /// `MACError`-free `isValidAuthenticationCode`, so a timing oracle cannot leak the code.
    public func verify(proof: Data, nonce: Data, deviceId: String) -> Channel? {
        var message = nonce
        message.append(Data(deviceId.utf8))
        for channel in [Channel.qr, .typedCode] {
            let key = SymmetricKey(data: key(for: channel))
            if HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: key) {
                return channel
            }
        }
        return nil
    }

    /// The URL encoded into the QR code. `fingerprint` is the base64url SHA-256 of the
    /// server certificate's SubjectPublicKeyInfo, which the client pins before sending anything.
    public func pairingURL(host: String, port: UInt16, fingerprint: String) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        // Carried in the fragment so it is never sent in an HTTP request line or logged
        // by any intermediary; the page reads it from `location.hash`.
        components.fragment = "s=\(secret.base64URLEncodedString())&f=\(fingerprint)&c=\(displayCode)"
        return components.string ?? ""
    }
}

/// A random challenge nonce, fresh per connection, so a captured `hello` cannot be replayed.
public enum Nonce {
    public static func generate(byteCount: Int = 32) -> Data {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        precondition(status == errSecSuccess, "secure random unavailable")
        return bytes
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
