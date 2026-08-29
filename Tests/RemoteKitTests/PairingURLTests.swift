import XCTest
import CryptoKit
@testable import RemoteKit

/// Reproduces exactly what the browser does with a scanned QR code, end to end:
/// parse the URL fragment, base64url-decode the secret, HMAC over `nonce || deviceId`,
/// and hand the result to the same verifier the server uses.
///
/// This exists because a real phone failed with `bad pairing proof` on the QR path while
/// the typed-code path succeeded — which localises the bug to the secret's trip through
/// the URL, not to the HMAC itself.
final class PairingURLTests: XCTestCase {

    private func fragmentParameters(of url: String) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(string: url))
        let fragment = try XCTUnwrap(components.fragment)
        var out: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = String(parts[1])
        }
        return out
    }

    func testPairingURLFragmentSurvivesRoundTrip() throws {
        let secret = PairingSecret()
        let url = secret.pairingURL(host: "10.0.0.25", port: 8443, fingerprint: "AbC-_123")
        let params = try fragmentParameters(of: url)

        let encoded = try XCTUnwrap(params["s"], "the QR must carry the secret")
        // The exact failure mode we are hunting: any percent-encoding applied by
        // URLComponents would make the browser decode different bytes than we encoded.
        XCTAssertFalse(encoded.contains("%"), "the secret must not be percent-encoded in the fragment")

        let decoded = try XCTUnwrap(Data(base64URLEncoded: encoded))
        XCTAssertEqual(decoded, secret.secret, "the secret must survive the URL round trip intact")
    }

    func testFingerprintSurvivesRoundTrip() throws {
        // Real fingerprints are base64url and contain '-' and '_'.
        let secret = PairingSecret()
        let fingerprint = Data(SHA256.hash(data: Data("cert".utf8))).base64URLEncodedString()
        let url = secret.pairingURL(host: "10.0.0.25", port: 8443, fingerprint: fingerprint)
        let params = try fragmentParameters(of: url)
        XCTAssertEqual(params["f"], fingerprint)
    }

    /// The browser's computation, byte for byte.
    private func browserProof(secretB64URL: String, nonce: Data, deviceId: String) throws -> Data {
        let keyBytes = try XCTUnwrap(Data(base64URLEncoded: secretB64URL))
        var message = nonce
        message.append(Data(deviceId.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keyBytes)))
    }

    func testProofComputedFromTheScannedURLVerifies() throws {
        let secret = PairingSecret()
        let deviceId = "ab2f4a6e00112233"
        let nonce = Nonce.generate()

        let url = secret.pairingURL(host: "10.0.0.25", port: 8443, fingerprint: "x")
        let encoded = try XCTUnwrap(try fragmentParameters(of: url)["s"])

        let proof = try browserProof(secretB64URL: encoded, nonce: nonce, deviceId: deviceId)
        XCTAssertEqual(secret.verify(proof: proof, nonce: nonce, deviceId: deviceId), .qr,
                       "a proof built from the scanned QR must verify on the QR channel")
    }

    func testTypedCodeProofStillVerifiesFromTheSameSecret() throws {
        let secret = PairingSecret()
        let deviceId = "ab2f4a6e00112233"
        let nonce = Nonce.generate()
        var message = nonce
        message.append(Data(deviceId.utf8))
        let proof = Data(HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: Data(secret.displayCode.utf8))))
        XCTAssertEqual(secret.verify(proof: proof, nonce: nonce, deviceId: deviceId), .typedCode)
    }
}
