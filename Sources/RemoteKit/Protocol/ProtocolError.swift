import Foundation

/// Wire-level error codes. These are the exact strings sent in `error.d.code`;
/// they are part of the protocol contract and must not be renamed without a version bump.
public enum ErrorCode: String, Codable, Sendable {
    case unsupportedVersion = "unsupported_version"
    case badJSON            = "bad_json"
    case unknownType        = "unknown_type"
    case invalidPayload     = "invalid_payload"
    case unauthenticated    = "unauthenticated"
    case pairRejected       = "pair_rejected"
    case pairTimeout        = "pair_timeout"
    case tooManyAttempts    = "too_many_attempts"
    case sessionExpired     = "session_expired"
    case sessionReplaced    = "session_replaced"
    case rateLimited        = "rate_limited"
    case permissionDenied   = "permission_denied"
    case frameTooLarge      = "frame_too_large"

    /// Whether receiving this error means the session is over.
    public var isFatal: Bool {
        switch self {
        case .badJSON, .unknownType, .invalidPayload, .rateLimited, .permissionDenied:
            return false
        case .unsupportedVersion, .unauthenticated, .pairRejected, .pairTimeout,
             .tooManyAttempts, .sessionExpired, .sessionReplaced, .frameTooLarge:
            return true
        }
    }
}

public struct ProtocolError: Error, Equatable, Sendable {
    public let code: ErrorCode
    public let message: String
    public let retryAfterMs: Int?

    public init(_ code: ErrorCode, _ message: String, retryAfterMs: Int? = nil) {
        self.code = code
        self.message = message
        self.retryAfterMs = retryAfterMs
    }

    public static func invalid(_ message: String) -> ProtocolError {
        ProtocolError(.invalidPayload, message)
    }
}
