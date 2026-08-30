import Foundation

public enum ClientEventType: String, Codable, CaseIterable, Sendable {
    case hello
    case pointerMove = "pointer_move"
    case leftClick = "left_click"
    case rightClick = "right_click"
    case dragStart = "drag_start"
    case dragEnd = "drag_end"
    case scroll
    case keyPress = "key_press"
    case textInput = "text_input"
    case mediaCommand = "media_command"
    case recenter
    case calibration
    case ping
    case disconnect
}

public enum ClientEvent: Equatable, Sendable {
    case hello(HelloPayload)
    case pointerMove(PointerMovePayload)
    case leftClick(ClickPayload)
    case rightClick(ClickPayload)
    case dragStart(DragPayload)
    case dragEnd(DragPayload)
    case scroll(ScrollPayload)
    case keyPress(KeyPressPayload)
    case textInput(TextInputPayload)
    case mediaCommand(MediaCommandPayload)
    case recenter(RecenterPayload)
    case calibration(CalibrationPayload)
    case ping(PingPayload)
    case disconnect(DisconnectPayload)

    public var type: ClientEventType {
        switch self {
        case .hello: return .hello
        case .pointerMove: return .pointerMove
        case .leftClick: return .leftClick
        case .rightClick: return .rightClick
        case .dragStart: return .dragStart
        case .dragEnd: return .dragEnd
        case .scroll: return .scroll
        case .keyPress: return .keyPress
        case .textInput: return .textInput
        case .mediaCommand: return .mediaCommand
        case .recenter: return .recenter
        case .calibration: return .calibration
        case .ping: return .ping
        case .disconnect: return .disconnect
        }
    }

    /// Whether this event may be processed before the session is authenticated.
    public var allowedBeforeAuth: Bool {
        switch self {
        case .hello, .ping, .disconnect: return true
        default: return false
        }
    }

    /// Motion-class events may be dropped or reordered without consequence;
    /// everything else must be applied exactly once, in order.
    public var isLossTolerant: Bool {
        switch self {
        case .pointerMove, .scroll: return true
        default: return false
        }
    }
}

/// A decoded, *not yet validated*, client message.
///
/// Decoding and validation are separate steps on purpose: decoding tells us what the client
/// meant, validation tells us whether we are willing to do it. Keeping them apart means the
/// session layer can log a well-formed-but-rejected message, which is what you actually want
/// when debugging a client.
public struct ClientMessage: Decodable, Sendable {
    public let v: Int
    public let seq: UInt32
    public let ts: Int64
    public let event: ClientEvent

    enum CodingKeys: String, CodingKey { case v, t, seq, ts, d }

    public init(v: Int = Limits.protocolVersion, seq: UInt32, ts: Int64, event: ClientEvent) {
        self.v = v; self.seq = seq; self.ts = ts; self.event = event
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 0
        guard v == Limits.protocolVersion else {
            throw ProtocolError(.unsupportedVersion, "expected protocol v\(Limits.protocolVersion), got v\(v)")
        }

        seq = try c.decodeIfPresent(UInt32.self, forKey: .seq) ?? 0
        ts = try c.decodeIfPresent(Int64.self, forKey: .ts) ?? 0

        let rawType = try c.decode(String.self, forKey: .t)
        guard let type = ClientEventType(rawValue: rawType) else {
            throw ProtocolError(.unknownType, "unknown event type '\(rawType)'")
        }

        // Payloads with all-optional fields tolerate a missing `d`; the rest require it.
        func payload<T: Decodable>(_ type: T.Type) throws -> T {
            guard c.contains(.d) else {
                throw ProtocolError.invalid("'\(rawType)' requires a payload")
            }
            return try c.decode(T.self, forKey: .d)
        }
        func optionalPayload<T: Decodable & ValidatablePayload>(_ type: T.Type, default def: T) throws -> T {
            (try? c.decodeIfPresent(T.self, forKey: .d)) .flatMap { $0 } ?? def
        }

        switch type {
        case .hello:         event = .hello(try payload(HelloPayload.self))
        case .pointerMove:   event = .pointerMove(try payload(PointerMovePayload.self))
        case .leftClick:     event = .leftClick(try optionalPayload(ClickPayload.self, default: ClickPayload()))
        case .rightClick:    event = .rightClick(try optionalPayload(ClickPayload.self, default: ClickPayload()))
        case .dragStart:     event = .dragStart(try optionalPayload(DragPayload.self, default: DragPayload()))
        case .dragEnd:       event = .dragEnd(try optionalPayload(DragPayload.self, default: DragPayload()))
        case .scroll:        event = .scroll(try payload(ScrollPayload.self))
        case .keyPress:      event = .keyPress(try payload(KeyPressPayload.self))
        case .textInput:     event = .textInput(try payload(TextInputPayload.self))
        case .mediaCommand:  event = .mediaCommand(try payload(MediaCommandPayload.self))
        case .recenter:      event = .recenter(try optionalPayload(RecenterPayload.self, default: RecenterPayload()))
        case .calibration:   event = .calibration(try payload(CalibrationPayload.self))
        case .ping:          event = .ping(try payload(PingPayload.self))
        case .disconnect:    event = .disconnect(try optionalPayload(DisconnectPayload.self, default: DisconnectPayload()))
        }
    }

    /// Normalises the payload, clamping what is clampable and throwing otherwise.
    public func validated() throws -> ClientMessage {
        let e: ClientEvent
        switch event {
        case .hello(let p):        e = .hello(try p.validated())
        case .pointerMove(let p):  e = .pointerMove(try p.validated())
        case .leftClick(let p):    e = .leftClick(try p.validated())
        case .rightClick(let p):   e = .rightClick(try p.validated())
        case .dragStart(let p):    e = .dragStart(try p.validated())
        case .dragEnd(let p):      e = .dragEnd(try p.validated())
        case .scroll(let p):       e = .scroll(try p.validated())
        case .keyPress(let p):     e = .keyPress(try p.validated())
        case .textInput(let p):    e = .textInput(try p.validated())
        case .mediaCommand(let p): e = .mediaCommand(try p.validated())
        case .recenter(let p):     e = .recenter(try p.validated())
        case .calibration(let p):  e = .calibration(try p.validated())
        case .ping(let p):         e = .ping(try p.validated())
        case .disconnect(let p):   e = .disconnect(try p.validated())
        }
        return ClientMessage(v: v, seq: seq, ts: ts, event: e)
    }

    /// Parses one wire frame. Frame-size and JSON errors are mapped onto protocol error codes
    /// so the caller never has to interpret a `DecodingError`.
    public static func decode(_ data: Data) throws -> ClientMessage {
        guard data.count <= Limits.maxFrameBytes else {
            throw ProtocolError(.frameTooLarge, "frame of \(data.count) bytes exceeds \(Limits.maxFrameBytes)")
        }
        do {
            return try JSONDecoder().decode(ClientMessage.self, from: data)
        } catch let error as ProtocolError {
            throw error
        } catch let error as DecodingError {
            throw ProtocolError.invalid(Self.describe(error))
        } catch {
            throw ProtocolError(.badJSON, "unparseable frame")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let ctx):
            return ctx.debugDescription.contains("JSON") ? "malformed JSON" : ctx.debugDescription
        case .keyNotFound(let key, _):
            return "missing field '\(key.stringValue)'"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return "wrong type for '\(path.isEmpty ? "?" : path)'"
        @unknown default:
            return "invalid payload"
        }
    }
}

// MARK: - Server → client

public enum ServerEventType: String, Sendable {
    case challenge, welcome, pairPending = "pair_pending", status, pong, error, focus
}

/// Server frames are encoded through one generic envelope so the version, sequence and
/// timestamp fields can never be forgotten on a new message type.
public struct ServerEnvelope<Payload: Encodable>: Encodable {
    public let v: Int
    public let t: String
    public let seq: UInt32
    public let ts: Int64
    public let d: Payload

    public init(type: ServerEventType, seq: UInt32, payload: Payload, ts: Int64 = Clock.nowMillis()) {
        self.v = Limits.protocolVersion
        self.t = type.rawValue
        self.seq = seq
        self.ts = ts
        self.d = payload
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

public struct ChallengePayload: Encodable, Sendable {
    public let nonce: String
    public let serverVersion: String
    public init(nonce: String, serverVersion: String) {
        self.nonce = nonce; self.serverVersion = serverVersion
    }
}

public struct DisplayInfo: Encodable, Sendable {
    public let id: Int
    public let w: Int
    public let h: Int
    public let scale: Double
    public let main: Bool
    public init(id: Int, w: Int, h: Int, scale: Double, main: Bool) {
        self.id = id; self.w = w; self.h = h; self.scale = scale; self.main = main
    }
}

public struct WelcomePayload: Encodable, Sendable {
    public let sessionId: String
    public let expiresAt: Int64
    public let displays: [DisplayInfo]
    public let features: [String]
    public let permissions: [String: Bool]
    public init(sessionId: String, expiresAt: Int64, displays: [DisplayInfo],
                features: [String], permissions: [String: Bool]) {
        self.sessionId = sessionId; self.expiresAt = expiresAt; self.displays = displays
        self.features = features; self.permissions = permissions
    }
}

public struct PairPendingPayload: Encodable, Sendable {
    public let message: String
    public let timeoutMs: Int
    public init(message: String, timeoutMs: Int) { self.message = message; self.timeoutMs = timeoutMs }
}

public struct StatusPayload: Encodable, Sendable {
    public let pointerEnabled: Bool
    public let accessibility: Bool
    public let activeDisplay: Int
    public let dragging: Bool
    public init(pointerEnabled: Bool, accessibility: Bool, activeDisplay: Int, dragging: Bool) {
        self.pointerEnabled = pointerEnabled; self.accessibility = accessibility
        self.activeDisplay = activeDisplay; self.dragging = dragging
    }
}

/// Tells the client whether the host's focused control accepts typed text, so the phone
/// can offer its keyboard at the moment it becomes useful.
///
/// Deliberately a single boolean. The host knows the focused element's role but sends none
/// of it: nothing about what is on screen, what application is frontmost, or what any field
/// contains ever crosses the wire.
public struct FocusPayload: Encodable, Sendable {
    public let textInput: Bool
    public init(textInput: Bool) { self.textInput = textInput }
}

public struct PongPayload: Encodable, Sendable {
    public let id: Int
    public let clientTs: Int64
    public init(id: Int, clientTs: Int64) { self.id = id; self.clientTs = clientTs }
}

public struct ErrorPayload: Encodable, Sendable {
    public let code: String
    public let message: String
    public let fatal: Bool
    public let retryAfterMs: Int?

    public init(_ error: ProtocolError) {
        self.code = error.code.rawValue
        self.message = error.message
        self.fatal = error.code.isFatal
        self.retryAfterMs = error.retryAfterMs
    }
}

public enum Clock {
    public static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
