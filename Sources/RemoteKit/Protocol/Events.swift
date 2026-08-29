import Foundation

// MARK: - Helpers

private func clamp(_ value: Double, _ limit: Double) -> Double {
    min(max(value, -limit), limit)
}

private func requireFinite(_ value: Double, _ field: String) throws -> Double {
    guard value.isFinite else { throw ProtocolError.invalid("\(field) must be finite") }
    return value
}

/// Payloads that can normalise themselves, clamping what is safe to clamp and
/// throwing on what is not. Validation lives with the type so there is exactly one
/// definition of "valid" shared by the server and any future client.
public protocol ValidatablePayload {
    func validated() throws -> Self
}

// MARK: - Client → server payloads

public struct HelloPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public struct Auth: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable { case code, resume }
        public var mode: Mode
        /// Base64 HMAC-SHA256(pairingSecret, nonce ‖ deviceId) for `.code`,
        /// or base64 Ed25519 signature over the same message for `.resume`.
        public var proof: String
        /// Ed25519 public key, base64. Required for `.code` when the user may choose "trust".
        public var publicKey: String?

        public init(mode: Mode, proof: String, publicKey: String? = nil) {
            self.mode = mode; self.proof = proof; self.publicKey = publicKey
        }
    }

    public var deviceId: String
    public var deviceName: String
    public var platform: String
    public var clientVersion: String
    public var auth: Auth

    public init(deviceId: String, deviceName: String, platform: String,
                clientVersion: String, auth: Auth) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.platform = platform
        self.clientVersion = clientVersion; self.auth = auth
    }

    public func validated() throws -> HelloPayload {
        var copy = self
        guard (1...64).contains(deviceId.count) else {
            throw ProtocolError.invalid("deviceId length")
        }
        guard deviceId.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw ProtocolError.invalid("deviceId must be hex")
        }
        // The device name is shown to a human in the approval dialog, so it must not be able
        // to carry control characters, spoof newlines, or run to an unreadable length.
        copy.deviceName = String(deviceName.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint
            && !CharacterSet.controlCharacters.contains($0) }).prefix(48).trimmingCharacters(in: .whitespaces)
        if copy.deviceName.isEmpty { copy.deviceName = "Unknown device" }
        guard (1...32).contains(platform.count), (1...32).contains(clientVersion.count) else {
            throw ProtocolError.invalid("platform/clientVersion length")
        }
        guard (1...512).contains(auth.proof.count), Data(base64Encoded: auth.proof) != nil else {
            throw ProtocolError.invalid("auth.proof must be base64")
        }
        if let key = auth.publicKey {
            guard let decoded = Data(base64Encoded: key), decoded.count == 32 else {
                throw ProtocolError.invalid("auth.publicKey must be a 32-byte base64 Ed25519 key")
            }
        }
        return copy
    }
}

public struct PointerMovePayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var dx: Double
    public var dy: Double
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }

    public func validated() throws -> PointerMovePayload {
        PointerMovePayload(
            dx: clamp(try requireFinite(dx, "dx"), Limits.maxPointerDelta),
            dy: clamp(try requireFinite(dy, "dy"), Limits.maxPointerDelta)
        )
    }
}

public struct ClickPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var clicks: Int
    public init(clicks: Int = 1) { self.clicks = clicks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clicks = try c.decodeIfPresent(Int.self, forKey: .clicks) ?? 1
    }
    public func validated() throws -> ClickPayload {
        guard (1...Limits.maxClicks).contains(clicks) else {
            throw ProtocolError.invalid("clicks must be 1...\(Limits.maxClicks)")
        }
        return self
    }
}

public struct DragPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var button: MouseButton
    public init(button: MouseButton = .left) { self.button = button }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = try c.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left
    }
    public func validated() throws -> DragPayload { self }
}

public struct ScrollPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public enum Unit: String, Codable, Sendable { case px, line }
    public var dx: Double
    public var dy: Double
    public var unit: Unit
    public var momentum: Bool

    public init(dx: Double, dy: Double, unit: Unit = .px, momentum: Bool = false) {
        self.dx = dx; self.dy = dy; self.unit = unit; self.momentum = momentum
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dx = try c.decodeIfPresent(Double.self, forKey: .dx) ?? 0
        dy = try c.decodeIfPresent(Double.self, forKey: .dy) ?? 0
        unit = try c.decodeIfPresent(Unit.self, forKey: .unit) ?? .px
        momentum = try c.decodeIfPresent(Bool.self, forKey: .momentum) ?? false
    }
    public func validated() throws -> ScrollPayload {
        ScrollPayload(dx: clamp(try requireFinite(dx, "dx"), Limits.maxScrollDelta),
                      dy: clamp(try requireFinite(dy, "dy"), Limits.maxScrollDelta),
                      unit: unit, momentum: momentum)
    }
}

public struct KeyPressPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var key: KeyName
    public var mods: [String]
    public var repeatCount: Int

    enum CodingKeys: String, CodingKey { case key, mods, repeatCount = "repeat" }

    public init(key: KeyName, mods: [String] = [], repeatCount: Int = 1) {
        self.key = key; self.mods = mods; self.repeatCount = repeatCount
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decoding KeyName from an unknown string throws a generic decoding error; translate it
        // so the client is told *why* rather than getting "data corrupted".
        let raw = try c.decode(String.self, forKey: .key)
        guard let name = KeyName(rawValue: raw) else {
            throw ProtocolError.invalid("key '\(raw)' is not in the allowlist")
        }
        key = name
        mods = try c.decodeIfPresent([String].self, forKey: .mods) ?? []
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
    }

    public var modifiers: KeyModifiers { (try? KeyModifiers.parse(mods)) ?? [] }

    public func validated() throws -> KeyPressPayload {
        guard mods.count <= 5 else { throw ProtocolError.invalid("too many modifiers") }
        _ = try KeyModifiers.parse(mods)
        guard (1...Limits.maxKeyRepeat).contains(repeatCount) else {
            throw ProtocolError.invalid("repeat must be 1...\(Limits.maxKeyRepeat)")
        }
        return self
    }
}

public struct TextInputPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var text: String
    public init(text: String) { self.text = text }

    public func validated() throws -> TextInputPayload {
        // Strip control characters except tab and newline. A remote that can inject arbitrary
        // C0/C1 into a text field can produce keystrokes the user never saw on their phone.
        let cleaned = String(text.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        })
        guard !cleaned.isEmpty else { throw ProtocolError.invalid("text is empty after sanitising") }
        guard cleaned.count <= Limits.maxTextLength else {
            throw ProtocolError.invalid("text exceeds \(Limits.maxTextLength) characters")
        }
        return TextInputPayload(text: cleaned)
    }
}

public struct MediaCommandPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var command: MediaCommandName
    public var amount: Double?

    public init(command: MediaCommandName, amount: Double? = nil) {
        self.command = command; self.amount = amount
    }
    public func validated() throws -> MediaCommandPayload {
        guard let amount else { return self }
        let finite = try requireFinite(amount, "amount")
        guard (Limits.minSeekAmount...Limits.maxSeekAmount).contains(finite) else {
            throw ProtocolError.invalid("amount must be \(Limits.minSeekAmount)...\(Limits.maxSeekAmount)")
        }
        return MediaCommandPayload(command: command, amount: finite)
    }
}

public struct RecenterPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var toCenter: Bool
    public init(toCenter: Bool = false) { self.toCenter = toCenter }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toCenter = try c.decodeIfPresent(Bool.self, forKey: .toCenter) ?? false
    }
    public func validated() throws -> RecenterPayload { self }
}

public struct CalibrationPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public enum Stage: String, Codable, Sendable { case start, sampling, complete, failed }
    public var stage: Stage
    public var holdMs: Double?
    public var biasRadS: [Double]?
    public var noiseRadS: Double?

    public init(stage: Stage, holdMs: Double? = nil, biasRadS: [Double]? = nil, noiseRadS: Double? = nil) {
        self.stage = stage; self.holdMs = holdMs; self.biasRadS = biasRadS; self.noiseRadS = noiseRadS
    }
    public func validated() throws -> CalibrationPayload {
        if let bias = biasRadS {
            guard bias.count == 3, bias.allSatisfy({ $0.isFinite && abs($0) <= 0.5 }) else {
                throw ProtocolError.invalid("biasRadS must be 3 finite values within ±0.5")
            }
        }
        if let noise = noiseRadS, !(noise.isFinite && noise >= 0 && noise <= 1) {
            throw ProtocolError.invalid("noiseRadS out of range")
        }
        if let hold = holdMs, !(hold.isFinite && hold >= 0 && hold <= 60_000) {
            throw ProtocolError.invalid("holdMs out of range")
        }
        return self
    }
}

public struct PingPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var id: Int
    public init(id: Int) { self.id = id }
    public func validated() throws -> PingPayload { self }
}

public struct DisconnectPayload: Codable, Equatable, Sendable, ValidatablePayload {
    public var reason: String
    public init(reason: String = "user_requested") { self.reason = reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? "user_requested"
    }
    public func validated() throws -> DisconnectPayload {
        DisconnectPayload(reason: String(reason.prefix(64)))
    }
}
