import Foundation

/// Token bucket. Deliberately allocation-free and monotonic-clock driven so it can be
/// called on the hot path for every inbound frame.
public struct TokenBucket: Sendable {
    public let capacity: Double
    public let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: TimeInterval

    public init(capacity: Double, refillPerSecond: Double, now: TimeInterval) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = now
    }

    public mutating func take(_ amount: Double = 1, now: TimeInterval) -> Bool {
        let elapsed = max(0, now - lastRefill)
        lastRefill = now
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        guard tokens >= amount else { return false }
        tokens -= amount
        return true
    }

    /// Milliseconds until `amount` tokens would be available. Used for `retryAfterMs`.
    public func retryAfterMs(_ amount: Double = 1) -> Int {
        guard tokens < amount, refillPerSecond > 0 else { return 0 }
        return Int(((amount - tokens) / refillPerSecond) * 1000) + 1
    }
}

/// Per-event-type rate limiting for one session.
///
/// Rejected frames are **dropped, never queued**. Queuing a motion delta makes it a lie by the
/// time it is applied, and queuing anything else lets a misbehaving client build an unbounded
/// backlog of input to execute on the user's machine.
public final class SessionRateLimiter {
    private var buckets: [ClientEventType: TokenBucket]
    private var global: TokenBucket

    public init(now: TimeInterval) {
        // capacity = burst allowance, refill = sustained rate/second
        buckets = [
            .pointerMove:  TokenBucket(capacity: 60, refillPerSecond: 150, now: now),
            .scroll:       TokenBucket(capacity: 60, refillPerSecond: 150, now: now),
            .leftClick:    TokenBucket(capacity: 10, refillPerSecond: 20, now: now),
            .rightClick:   TokenBucket(capacity: 10, refillPerSecond: 20, now: now),
            .dragStart:    TokenBucket(capacity: 5,  refillPerSecond: 10, now: now),
            .dragEnd:      TokenBucket(capacity: 5,  refillPerSecond: 10, now: now),
            .keyPress:     TokenBucket(capacity: 20, refillPerSecond: 40, now: now),
            .textInput:    TokenBucket(capacity: 10, refillPerSecond: 20, now: now),
            .mediaCommand: TokenBucket(capacity: 10, refillPerSecond: 20, now: now),
            .recenter:     TokenBucket(capacity: 3,  refillPerSecond: 5,  now: now),
            .calibration:  TokenBucket(capacity: 5,  refillPerSecond: 2,  now: now),
            .ping:         TokenBucket(capacity: 5,  refillPerSecond: 5,  now: now),
            .hello:        TokenBucket(capacity: 3,  refillPerSecond: 1,  now: now),
            .disconnect:   TokenBucket(capacity: 3,  refillPerSecond: 1,  now: now),
        ]
        global = TokenBucket(capacity: 200, refillPerSecond: 400, now: now)
    }

    /// Returns nil if allowed, or the error to return to the client.
    ///
    /// The per-type bucket is checked **first** and a frame it rejects never touches the
    /// global bucket. Order matters: if a pointer_move flood could drain the global budget,
    /// a misbehaving (or malicious) client would be able to starve the user's ability to
    /// click or disconnect. The global bucket is a backstop against aggregate load, not the
    /// primary control.
    public func allow(_ type: ClientEventType, now: TimeInterval) -> ProtocolError? {
        if var bucket = buckets[type] {
            let allowed = bucket.take(now: now)
            buckets[type] = bucket
            guard allowed else {
                return ProtocolError(.rateLimited, "\(type.rawValue) rate exceeded",
                                     retryAfterMs: bucket.retryAfterMs())
            }
        }
        guard global.take(now: now) else {
            return ProtocolError(.rateLimited, "global frame rate exceeded",
                                 retryAfterMs: global.retryAfterMs())
        }
        return nil
    }
}

/// Tracks failed pairing attempts per peer address and applies a lockout.
/// This is what makes a 6-digit code defensible against online guessing.
public final class AttemptTracker {
    private struct Record { var failures: Int; var lockedUntil: TimeInterval? }
    private var records: [String: Record] = [:]
    private let maxAttempts: Int
    private let lockout: TimeInterval

    public init(maxAttempts: Int = Limits.maxPairingAttempts, lockout: TimeInterval = Limits.pairingLockout) {
        self.maxAttempts = maxAttempts
        self.lockout = lockout
    }

    public func isLocked(_ peer: String, now: TimeInterval) -> Bool {
        guard let until = records[peer]?.lockedUntil else { return false }
        if now >= until {
            records[peer] = nil
            return false
        }
        return true
    }

    public func recordFailure(_ peer: String, now: TimeInterval) {
        var record = records[peer] ?? Record(failures: 0, lockedUntil: nil)
        record.failures += 1
        if record.failures >= maxAttempts { record.lockedUntil = now + lockout }
        records[peer] = record
    }

    public func recordSuccess(_ peer: String) { records[peer] = nil }

    public func remainingLockoutMs(_ peer: String, now: TimeInterval) -> Int {
        guard let until = records[peer]?.lockedUntil, until > now else { return 0 }
        return Int((until - now) * 1000)
    }
}
