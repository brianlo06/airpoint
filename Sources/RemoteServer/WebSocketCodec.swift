import Foundation
import CryptoKit
import RemoteKit

/// Minimal RFC 6455 framing.
///
/// Hand-rolled rather than using `NWProtocolWebSocket` for two reasons that both matter
/// here: Apple's server-side WebSocket option hides the HTTP upgrade request, so we could
/// not enforce the `Origin`/`Host` allowlist that defends against a malicious web page
/// (threat T4); and it cannot share a listener with the plain HTTP that serves the
/// controller, which Safari's per-host certificate exception model requires.
///
/// The scope is deliberately small: text and binary data frames, close, ping, pong,
/// fragmentation, and mandatory client masking. No extensions, no compression.
enum WebSocket {

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA

        var isControl: Bool { rawValue & 0x8 != 0 }
    }

    struct Frame {
        let isFinal: Bool
        let opcode: Opcode
        let payload: Data
    }

    /// RFC 6455 close codes we actually use.
    enum CloseCode: UInt16 {
        case normal = 1000
        case goingAway = 1001
        case protocolError = 1002
        case policyViolation = 1008
        case messageTooBig = 1009
        case internalError = 1011
    }

    enum CodecError: Error, CustomStringConvertible {
        case reservedBitsSet
        case unknownOpcode(UInt8)
        case unmaskedClientFrame
        case controlFrameTooLarge
        case fragmentedControlFrame
        case messageTooLarge(Int)
        case invalidContinuation

        var description: String {
            switch self {
            case .reservedBitsSet: return "RSV bits set but no extension negotiated"
            case .unknownOpcode(let op): return "unknown opcode 0x\(String(op, radix: 16))"
            case .unmaskedClientFrame: return "client frame was not masked"
            case .controlFrameTooLarge: return "control frame payload exceeds 125 bytes"
            case .fragmentedControlFrame: return "control frames may not be fragmented"
            case .messageTooLarge(let size): return "message of \(size) bytes exceeds the limit"
            case .invalidContinuation: return "continuation frame with no message in progress"
            }
        }
    }

    // MARK: - Decoding

    /// Attempts to pull one frame off the front of `buffer`.
    ///
    /// Returns nil when the buffer holds an incomplete frame; the caller keeps reading.
    /// On success, the consumed bytes are removed from `buffer`.
    static func decodeFrame(from buffer: inout Data) throws -> Frame? {
        guard buffer.count >= 2 else { return nil }

        // Index arithmetic below is relative to startIndex: a Data sliced from another Data
        // keeps the parent's indices, and assuming 0-based here is a classic source of
        // off-by-large-number bugs.
        let base = buffer.startIndex
        let byte0 = buffer[base]
        let byte1 = buffer[base + 1]

        guard byte0 & 0x70 == 0 else { throw CodecError.reservedBitsSet }
        guard let opcode = Opcode(rawValue: byte0 & 0x0F) else {
            throw CodecError.unknownOpcode(byte0 & 0x0F)
        }
        let isFinal = byte0 & 0x80 != 0
        let isMasked = byte1 & 0x80 != 0
        guard isMasked else { throw CodecError.unmaskedClientFrame }

        if opcode.isControl {
            guard isFinal else { throw CodecError.fragmentedControlFrame }
            guard byte1 & 0x7F <= 125 else { throw CodecError.controlFrameTooLarge }
        }

        var offset = base + 2
        let lengthMarker = byte1 & 0x7F
        var payloadLength: Int

        switch lengthMarker {
        case 126:
            guard buffer.count >= 4 else { return nil }
            payloadLength = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
            offset += 2
        case 127:
            guard buffer.count >= 10 else { return nil }
            var value: UInt64 = 0
            for i in 0..<8 { value = value << 8 | UInt64(buffer[offset + i]) }
            // Reject before allocating: a 2^63-byte length field must not become an
            // allocation attempt.
            guard value <= UInt64(Limits.maxFrameBytes) else {
                throw CodecError.messageTooLarge(Int(clamping: value))
            }
            payloadLength = Int(value)
            offset += 8
        default:
            payloadLength = Int(lengthMarker)
        }

        guard payloadLength <= Limits.maxFrameBytes else {
            throw CodecError.messageTooLarge(payloadLength)
        }

        let maskEnd = offset + 4
        guard buffer.count >= maskEnd - base + payloadLength else { return nil }
        let mask = [UInt8](buffer[offset..<maskEnd])
        offset = maskEnd

        var payload = Data(buffer[offset..<(offset + payloadLength)])
        for i in 0..<payload.count {
            payload[payload.startIndex + i] ^= mask[i % 4]
        }

        buffer.removeSubrange(base..<(offset + payloadLength))
        return Frame(isFinal: isFinal, opcode: opcode, payload: payload)
    }

    // MARK: - Encoding

    /// Server-to-client frames are never masked (RFC 6455 §5.1).
    static func encodeFrame(opcode: Opcode, payload: Data) -> Data {
        var out = Data()
        out.append(0x80 | opcode.rawValue)

        switch payload.count {
        case 0...125:
            out.append(UInt8(payload.count))
        case 126...0xFFFF:
            out.append(126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }

    static func encodeText(_ text: String) -> Data {
        encodeFrame(opcode: .text, payload: Data(text.utf8))
    }

    static func encodeClose(_ code: CloseCode, reason: String = "") -> Data {
        var payload = Data()
        payload.append(UInt8(code.rawValue >> 8))
        payload.append(UInt8(code.rawValue & 0xFF))
        // Close reasons are capped at 123 bytes so the whole control frame fits in 125.
        payload.append(Data(reason.utf8.prefix(123)))
        return encodeFrame(opcode: .close, payload: payload)
    }

    // MARK: - Handshake

    /// The fixed GUID from RFC 6455 §1.3.
    private static let handshakeGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + handshakeGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// Assembles fragmented messages and enforces the total size cap across fragments.
    /// Without the cap, a client could send a million 1-byte continuation frames and each
    /// one would pass the per-frame check.
    struct MessageAssembler {
        private var buffer = Data()
        private var opcode: Opcode?

        /// Returns a complete message, or nil if more fragments are expected.
        mutating func accept(_ frame: Frame) throws -> (opcode: Opcode, payload: Data)? {
            if frame.opcode.isControl { return (frame.opcode, frame.payload) }

            if frame.opcode == .continuation {
                guard let current = opcode else { throw CodecError.invalidContinuation }
                buffer.append(frame.payload)
                guard buffer.count <= Limits.maxFrameBytes else {
                    throw CodecError.messageTooLarge(buffer.count)
                }
                guard frame.isFinal else { return nil }
                let payload = buffer
                reset()
                return (current, payload)
            }

            if frame.isFinal && buffer.isEmpty {
                return (frame.opcode, frame.payload)
            }

            opcode = frame.opcode
            buffer = frame.payload
            guard buffer.count <= Limits.maxFrameBytes else {
                throw CodecError.messageTooLarge(buffer.count)
            }
            return nil
        }

        mutating func reset() {
            buffer.removeAll(keepingCapacity: false)
            opcode = nil
        }
    }
}
