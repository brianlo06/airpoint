import Foundation
import Security
import CryptoKit
import RemoteKit

/// A device the user explicitly chose to remember.
struct TrustedDevice: Codable {
    let deviceId: String
    let deviceName: String
    /// Base64 Ed25519 public key. Reconnects are authenticated by signing the server's nonce.
    let publicKey: String
    let trustedAt: Date
    var lastSeenAt: Date
}

/// The set of devices allowed to reconnect without a human approving it.
///
/// That is exactly why these records are secrets and not configuration: possession of a
/// matching private key is what skips the approval dialog. Storage backend is chosen by
/// `SecretStore` — permission-restricted files for the CLI, Keychain for a signed host.
final class TrustStore {

    private let secrets: SecretStore
    private let queue = DispatchQueue(label: "com.airpoint.truststore")

    init(secrets: SecretStore) { self.secrets = secrets }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func all() -> [TrustedDevice] {
        queue.sync {
            guard let accounts = try? secrets.allAccounts() else { return [] }
            let decoder = Self.makeDecoder()
            return accounts.compactMap { account in
                guard let data = (try? secrets.get(account: account)) ?? nil else { return nil }
                return try? decoder.decode(TrustedDevice.self, from: data)
            }
        }
    }

    func device(withId deviceId: String) -> TrustedDevice? {
        guard let data = (try? secrets.get(account: deviceId)) ?? nil else { return nil }
        return try? Self.makeDecoder().decode(TrustedDevice.self, from: data)
    }

    @discardableResult
    func trust(deviceId: String, deviceName: String, publicKey: String) -> Bool {
        let device = TrustedDevice(deviceId: deviceId, deviceName: deviceName,
                                   publicKey: publicKey, trustedAt: Date(), lastSeenAt: Date())
        return save(device)
    }

    @discardableResult
    func recordSeen(_ device: TrustedDevice) -> Bool {
        var updated = device
        updated.lastSeenAt = Date()
        return save(updated)
    }

    private func save(_ device: TrustedDevice) -> Bool {
        queue.sync {
            do {
                let data = try Self.makeEncoder().encode(device)
                try secrets.set(data, account: device.deviceId)
                return true
            } catch {
                Log.warn("could not store trusted device: \(error)")
                return false
            }
        }
    }

    @discardableResult
    func revoke(deviceId: String) -> Bool {
        queue.sync {
            do { try secrets.delete(account: deviceId); return true }
            catch { Log.warn("could not revoke device: \(error)"); return false }
        }
    }

    @discardableResult
    func revokeAll() -> Bool {
        queue.sync {
            do { try secrets.deleteAll(); return true }
            catch { Log.warn("could not revoke all devices: \(error)"); return false }
        }
    }

    /// Verifies a reconnect signature over the server's challenge nonce.
    func verifyResumeSignature(device: TrustedDevice, nonce: Data, signature: Data) -> Bool {
        guard let keyData = Data(base64Encoded: device.publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            Log.warn("trusted device \(Log.short(device.deviceId)) has an unusable public key")
            return false
        }
        var message = nonce
        message.append(Data(device.deviceId.utf8))
        return key.isValidSignature(signature, for: message)
    }
}
