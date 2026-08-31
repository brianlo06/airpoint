import XCTest
@testable import RemoteKit
import RemoteServer

final class RateLimiterTests: XCTestCase {

    func testBucketAllowsBurstThenThrottles() {
        var bucket = TokenBucket(capacity: 5, refillPerSecond: 10, now: 0)
        for i in 0..<5 {
            XCTAssertTrue(bucket.take(now: 0), "burst token \(i) should be allowed")
        }
        XCTAssertFalse(bucket.take(now: 0), "burst allowance must be finite")
    }

    func testBucketRefillsOverTime() {
        var bucket = TokenBucket(capacity: 5, refillPerSecond: 10, now: 0)
        for _ in 0..<5 { _ = bucket.take(now: 0) }
        XCTAssertFalse(bucket.take(now: 0))
        XCTAssertTrue(bucket.take(now: 0.2), "0.2 s at 10/s refills 2 tokens")
    }

    func testBucketNeverExceedsCapacity() {
        var bucket = TokenBucket(capacity: 5, refillPerSecond: 10, now: 0)
        // A very long idle period must not build an unbounded credit.
        for i in 0..<5 { XCTAssertTrue(bucket.take(now: 1_000_000 + Double(i) * 1e-6)) }
        XCTAssertFalse(bucket.take(now: 1_000_000))
    }

    func testRetryAfterIsPositiveWhenEmpty() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 10, now: 0)
        _ = bucket.take(now: 0)
        XCTAssertGreaterThan(bucket.retryAfterMs(), 0)
    }

    func testSessionLimiterThrottlesPointerFloodButKeepsSessionUsable() {
        let limiter = SessionRateLimiter(now: 0)
        var throttled = 0
        for i in 0..<300 {
            if limiter.allow(.pointerMove, now: Double(i) * 1e-4) != nil { throttled += 1 }
        }
        XCTAssertGreaterThan(throttled, 0, "a 10 kHz pointer flood must be throttled")
        // A click at the same instant must still get through: per-type buckets mean a
        // pointer flood cannot starve the user's ability to click.
        XCTAssertNil(limiter.allow(.leftClick, now: 0.03))
    }

    func testRateLimitErrorIsNotFatal() {
        let limiter = SessionRateLimiter(now: 0)
        var error: ProtocolError?
        for i in 0..<500 where error == nil {
            error = limiter.allow(.textInput, now: Double(i) * 1e-5)
        }
        XCTAssertEqual(error?.code, .rateLimited)
        XCTAssertFalse(ErrorCode.rateLimited.isFatal, "throttling must not kill the session")
    }
}

final class AttemptTrackerTests: XCTestCase {

    func testLocksOutAfterMaxAttempts() {
        let tracker = AttemptTracker(maxAttempts: 3, lockout: 60)
        XCTAssertFalse(tracker.isLocked("10.0.0.9", now: 0))
        for _ in 0..<3 { tracker.recordFailure("10.0.0.9", now: 0) }
        XCTAssertTrue(tracker.isLocked("10.0.0.9", now: 0))
    }

    func testLockoutExpires() {
        let tracker = AttemptTracker(maxAttempts: 2, lockout: 60)
        tracker.recordFailure("10.0.0.9", now: 0)
        tracker.recordFailure("10.0.0.9", now: 0)
        XCTAssertTrue(tracker.isLocked("10.0.0.9", now: 30))
        XCTAssertFalse(tracker.isLocked("10.0.0.9", now: 61))
    }

    func testLockoutIsPerPeer() {
        let tracker = AttemptTracker(maxAttempts: 2, lockout: 60)
        tracker.recordFailure("10.0.0.9", now: 0)
        tracker.recordFailure("10.0.0.9", now: 0)
        XCTAssertTrue(tracker.isLocked("10.0.0.9", now: 0))
        XCTAssertFalse(tracker.isLocked("10.0.0.10", now: 0),
                       "one bad actor must not lock out the household")
    }

    func testSuccessClearsHistory() {
        let tracker = AttemptTracker(maxAttempts: 3, lockout: 60)
        tracker.recordFailure("10.0.0.9", now: 0)
        tracker.recordFailure("10.0.0.9", now: 0)
        tracker.recordSuccess("10.0.0.9")
        tracker.recordFailure("10.0.0.9", now: 0)
        XCTAssertFalse(tracker.isLocked("10.0.0.9", now: 0))
    }
}

final class PairingTests: XCTestCase {

    func testDisplayCodeIsSixDigits() {
        for _ in 0..<20 {
            let secret = PairingSecret()
            XCTAssertEqual(secret.displayCode.count, 6)
            XCTAssertTrue(secret.displayCode.allSatisfy(\.isNumber))
        }
    }

    func testSecretsAreUnique() {
        let codes = Set((0..<200).map { _ in PairingSecret().secret })
        XCTAssertEqual(codes.count, 200, "pairing secrets must not repeat")
    }

    func testQRProofVerifies() {
        let secret = PairingSecret()
        let nonce = Nonce.generate()
        let proof = secret.expectedProof(nonce: nonce, deviceId: "abc123", channel: .qr)
        XCTAssertEqual(secret.verify(proof: proof, nonce: nonce, deviceId: "abc123"), .qr)
    }

    func testTypedCodeProofVerifies() {
        let secret = PairingSecret()
        let nonce = Nonce.generate()
        let proof = secret.expectedProof(nonce: nonce, deviceId: "abc123", channel: .typedCode)
        XCTAssertEqual(secret.verify(proof: proof, nonce: nonce, deviceId: "abc123"), .typedCode)
    }

    func testProofIsBoundToTheNonce() {
        let secret = PairingSecret()
        let proof = secret.expectedProof(nonce: Nonce.generate(), deviceId: "abc123", channel: .qr)
        // Replaying a captured proof against a fresh challenge must fail.
        XCTAssertNil(secret.verify(proof: proof, nonce: Nonce.generate(), deviceId: "abc123"))
    }

    func testProofIsBoundToTheDeviceId() {
        let secret = PairingSecret()
        let nonce = Nonce.generate()
        let proof = secret.expectedProof(nonce: nonce, deviceId: "abc123", channel: .qr)
        XCTAssertNil(secret.verify(proof: proof, nonce: nonce, deviceId: "deadbe"))
    }

    func testWrongSecretFails() {
        let nonce = Nonce.generate()
        let proof = PairingSecret().expectedProof(nonce: nonce, deviceId: "abc123", channel: .qr)
        XCTAssertNil(PairingSecret().verify(proof: proof, nonce: nonce, deviceId: "abc123"))
    }

    func testExpiry() {
        let created = Date()
        let secret = PairingSecret(ttl: 90, now: created)
        XCTAssertFalse(secret.isExpired(now: created.addingTimeInterval(89)))
        XCTAssertTrue(secret.isExpired(now: created.addingTimeInterval(91)))
        XCTAssertEqual(secret.remainingSeconds(now: created.addingTimeInterval(30)), 60)
    }

    func testPairingURLCarriesSecretInFragmentOnly() {
        let secret = PairingSecret()
        let url = secret.pairingURL(host: "10.0.0.25", port: 8443, fingerprint: "AAAA")
        let components = URLComponents(string: url)
        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.port, 8443)
        // The secret must never appear in the path or query, where it would be logged
        // by proxies, appear in Referer headers, or land in browser history entries.
        XCTAssertNil(components?.query)
        XCTAssertFalse(components?.path.contains(secret.displayCode) ?? true)
        XCTAssertTrue(components?.fragment?.contains("f=AAAA") ?? false)
    }

    func testBase64URLRoundTrip() {
        let data = Nonce.generate(byteCount: 33)   // odd length forces padding
        let encoded = data.base64URLEncodedString()
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: encoded), data)
    }

    func testNonceIsRequestedLength() {
        XCTAssertEqual(Nonce.generate(byteCount: 32).count, 32)
        XCTAssertNotEqual(Nonce.generate(), Nonce.generate())
    }
}

/// Which addresses this software is willing to bind.
///
/// The interesting case is 100.64.0.0/10: mesh VPNs like Tailscale use it, and so do ISPs
/// for real carrier NAT. On a tunnel it is a private overlay and binding it is how remote
/// play should work; on a physical interface it is the carrier's network and binding it
/// would expose input control to strangers. Same range, opposite meaning.
final class BindPolicyTests: XCTestCase {

    func testConventionalPrivateRangesAreAllowed() {
        for address in ["10.0.0.25", "192.168.1.4", "172.16.5.9", "172.31.255.1", "127.0.0.1"] {
            XCTAssertTrue(NetworkInterfaces.isPrivateAddress(address, isIPv4: true, interface: "en0"),
                          "\(address) should be bindable")
        }
    }

    func testPublicAddressesAreRefused() {
        for address in ["8.8.8.8", "1.1.1.1", "172.32.0.1", "93.184.216.34"] {
            XCTAssertFalse(NetworkInterfaces.isPrivateAddress(address, isIPv4: true, interface: "en0"),
                           "\(address) must not be bindable")
        }
    }

    func testCarrierNatIsRefusedOnAPhysicalInterface() {
        XCTAssertTrue(NetworkInterfaces.isCarrierGradeNAT("100.64.0.1"))
        XCTAssertTrue(NetworkInterfaces.isCarrierGradeNAT("100.127.255.254"))
        XCTAssertFalse(NetworkInterfaces.isPrivateAddress("100.100.5.7", isIPv4: true, interface: "en0"),
                       "an ISP's carrier NAT address must not be bindable")
    }

    func testCarrierNatIsAllowedOnAVpnTunnel() {
        XCTAssertTrue(NetworkInterfaces.isPrivateAddress("100.100.5.7", isIPv4: true, interface: "utun4"),
                      "a mesh VPN address is how remote play works")
        XCTAssertTrue(NetworkInterfaces.isPrivateAddress("100.64.9.9", isIPv4: true, interface: "tailscale0"))
    }

    func testAddressesOutsideTheCarrierRangeAreUnaffectedByTheInterface() {
        XCTAssertFalse(NetworkInterfaces.isPrivateAddress("8.8.8.8", isIPv4: true, interface: "utun4"),
                       "a tunnel must not launder a public address")
        XCTAssertTrue(NetworkInterfaces.isPrivateAddress("192.168.0.2", isIPv4: true, interface: "utun4"))
    }

    func testUnknownInterfaceDefaultsToRefusingCarrierNat() {
        XCTAssertFalse(NetworkInterfaces.isPrivateAddress("100.100.5.7", isIPv4: true))
    }
}
