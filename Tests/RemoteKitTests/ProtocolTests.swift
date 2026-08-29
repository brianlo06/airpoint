import XCTest
@testable import RemoteKit

final class ProtocolTests: XCTestCase {

    private func decode(_ json: String) throws -> ClientMessage {
        try ClientMessage.decode(Data(json.utf8))
    }

    // MARK: Envelope

    func testDecodesPointerMove() throws {
        let m = try decode(#"{"v":1,"t":"pointer_move","seq":42,"ts":1700,"d":{"dx":4.5,"dy":-1.25}}"#)
        XCTAssertEqual(m.seq, 42)
        XCTAssertEqual(m.ts, 1700)
        guard case .pointerMove(let p) = m.event else { return XCTFail("wrong event") }
        XCTAssertEqual(p.dx, 4.5)
        XCTAssertEqual(p.dy, -1.25)
    }

    func testRejectsWrongVersion() {
        XCTAssertThrowsError(try decode(#"{"v":2,"t":"ping","d":{"id":1}}"#)) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .unsupportedVersion)
        }
    }

    func testRejectsMissingVersion() {
        XCTAssertThrowsError(try decode(#"{"t":"ping","d":{"id":1}}"#)) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .unsupportedVersion)
        }
    }

    func testRejectsUnknownType() {
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"exec_shell","d":{}}"#)) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .unknownType)
        }
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try decode("{not json")) { error in
            let code = (error as? ProtocolError)?.code
            XCTAssertTrue(code == .badJSON || code == .invalidPayload)
        }
    }

    func testRejectsOversizedFrame() {
        let big = Data(count: Limits.maxFrameBytes + 1)
        XCTAssertThrowsError(try ClientMessage.decode(big)) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .frameTooLarge)
        }
    }

    func testEventsWithAllOptionalFieldsTolerateMissingPayload() throws {
        guard case .leftClick(let click) = try decode(#"{"v":1,"t":"left_click"}"#).event else {
            return XCTFail("wrong event")
        }
        XCTAssertEqual(click.clicks, 1)
    }

    func testEventsRequiringPayloadRejectMissingPayload() {
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"text_input"}"#)) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .invalidPayload)
        }
    }

    // MARK: Validation — clamping

    func testPointerDeltaIsClampedNotRejected() throws {
        let m = try decode(#"{"v":1,"t":"pointer_move","d":{"dx":99999,"dy":-99999}}"#).validated()
        guard case .pointerMove(let p) = m.event else { return XCTFail("wrong event") }
        XCTAssertEqual(p.dx, Limits.maxPointerDelta)
        XCTAssertEqual(p.dy, -Limits.maxPointerDelta)
    }

    func testOverflowingPointerDeltaIsRejectedAtDecode() {
        // JSON has no literal NaN, so a hostile client smuggles infinity via a huge exponent.
        // JSONDecoder refuses it outright, which is the outcome we want; assert the mapped code.
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"pointer_move","d":{"dx":1e400,"dy":0}}"#)) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .invalidPayload)
        }
    }

    func testNonFinitePointerDeltaIsRejectedByValidation() {
        // Belt and braces: validation must reject non-finite values even if some future
        // decoder (or a binary frame format) lets them through.
        XCTAssertThrowsError(try PointerMovePayload(dx: .infinity, dy: 0).validated())
        XCTAssertThrowsError(try PointerMovePayload(dx: 0, dy: .nan).validated())
    }

    func testScrollIsClamped() throws {
        let m = try decode(#"{"v":1,"t":"scroll","d":{"dx":0,"dy":-100000}}"#).validated()
        guard case .scroll(let s) = m.event else { return XCTFail("wrong event") }
        XCTAssertEqual(s.dy, -Limits.maxScrollDelta)
    }

    func testClickCountBounds() throws {
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"left_click","d":{"clicks":7}}"#).validated())
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"left_click","d":{"clicks":0}}"#).validated())
        XCTAssertNoThrow(try decode(#"{"v":1,"t":"left_click","d":{"clicks":2}}"#).validated())
    }

    // MARK: Validation — the key allowlist

    func testKeyAllowlistRejectsUnknownKey() {
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"key_press","d":{"key":"Eject"}}"#)) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .invalidPayload)
        }
    }

    func testKeyAllowlistRejectsInjectionAttempt() {
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"key_press","d":{"key":"; rm -rf /"}}"#))
    }

    func testUnknownModifierIsRejectedNotIgnored() throws {
        let m = try decode(#"{"v":1,"t":"key_press","d":{"key":"a","mods":["hyper"]}}"#)
        XCTAssertThrowsError(try m.validated())
    }

    func testKeyRepeatBounds() throws {
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"key_press","d":{"key":"a","repeat":99}}"#).validated())
        XCTAssertNoThrow(try decode(#"{"v":1,"t":"key_press","d":{"key":"a","repeat":10}}"#).validated())
    }

    func testModifierParsingAcceptsAliases() throws {
        XCTAssertEqual(try KeyModifiers.parse(["cmd", "meta"]), .command)
        XCTAssertEqual(try KeyModifiers.parse(["option"]), .option)
    }

    // MARK: Validation — text

    func testTextInputStripsControlCharacters() throws {
        // \u0007 (BEL) and \u0001 (SOH) must not survive into synthesised keystrokes.
        let m = try decode(#"{"v":1,"t":"text_input","d":{"text":"hello\u0007world\u0001"}}"#).validated()
        guard case .textInput(let t) = m.event else { return XCTFail("wrong event") }
        XCTAssertEqual(t.text, "helloworld")
    }

    func testTextInputKeepsTabAndNewline() throws {
        let m = try decode(#"{"v":1,"t":"text_input","d":{"text":"a\tb\nc"}}"#).validated()
        guard case .textInput(let t) = m.event else { return XCTFail("wrong event") }
        XCTAssertEqual(t.text, "a\tb\nc")
    }

    func testTextInputLengthCap() throws {
        let long = String(repeating: "x", count: Limits.maxTextLength + 1)
        let m = try decode(#"{"v":1,"t":"text_input","d":{"text":"\#(long)"}}"#)
        XCTAssertThrowsError(try m.validated())
    }

    func testTextThatIsEntirelyControlCharactersIsRejected() throws {
        let m = try decode(#"{"v":1,"t":"text_input","d":{"text":"\u0001\u0002"}}"#)
        XCTAssertThrowsError(try m.validated())
    }

    // MARK: Media / hello

    func testMediaSeekAmountBounds() throws {
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"media_command","d":{"command":"seek_forward","amount":9999}}"#).validated())
        XCTAssertNoThrow(try decode(#"{"v":1,"t":"media_command","d":{"command":"seek_forward","amount":10}}"#).validated())
    }

    func testMediaRejectsUnknownCommand() {
        XCTAssertThrowsError(try decode(#"{"v":1,"t":"media_command","d":{"command":"format_disk"}}"#))
    }

    func testHelloSanitisesDeviceName() throws {
        let json = #"{"v":1,"t":"hello","d":{"deviceId":"abc123","deviceName":"Evil\nName\u0007","platform":"ios-web","clientVersion":"0.1.0","auth":{"mode":"code","proof":"YWJj"}}}"#
        let m = try decode(json).validated()
        guard case .hello(let h) = m.event else { return XCTFail("wrong event") }
        XCTAssertFalse(h.deviceName.contains("\n"))
        XCTAssertFalse(h.deviceName.contains("\u{07}"))
        XCTAssertEqual(h.deviceName, "EvilName")
    }

    func testHelloRejectsNonHexDeviceId() throws {
        let json = #"{"v":1,"t":"hello","d":{"deviceId":"../../etc/passwd","deviceName":"x","platform":"ios-web","clientVersion":"0.1.0","auth":{"mode":"code","proof":"YWJj"}}}"#
        XCTAssertThrowsError(try decode(json).validated())
    }

    func testHelloRejectsNonBase64Proof() throws {
        let json = #"{"v":1,"t":"hello","d":{"deviceId":"abc123","deviceName":"x","platform":"ios-web","clientVersion":"0.1.0","auth":{"mode":"code","proof":"not base64!!"}}}"#
        XCTAssertThrowsError(try decode(json).validated())
    }

    // MARK: Event classification

    func testAuthGatingClassification() {
        XCTAssertTrue(ClientEvent.ping(PingPayload(id: 1)).allowedBeforeAuth)
        XCTAssertFalse(ClientEvent.pointerMove(PointerMovePayload(dx: 1, dy: 1)).allowedBeforeAuth)
        XCTAssertFalse(ClientEvent.textInput(TextInputPayload(text: "x")).allowedBeforeAuth)
    }

    func testLossToleranceClassification() {
        XCTAssertTrue(ClientEvent.pointerMove(PointerMovePayload(dx: 1, dy: 1)).isLossTolerant)
        XCTAssertFalse(ClientEvent.leftClick(ClickPayload()).isLossTolerant)
    }

    // MARK: Server encoding

    func testServerEnvelopeCarriesVersionAndType() throws {
        let payload = PongPayload(id: 7, clientTs: 123)
        let data = try ServerEnvelope(type: .pong, seq: 3, payload: payload).encoded()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["v"] as? Int, 1)
        XCTAssertEqual(object?["t"] as? String, "pong")
        XCTAssertEqual(object?["seq"] as? Int, 3)
    }

    func testErrorPayloadMarksFatality() throws {
        XCTAssertTrue(ErrorPayload(ProtocolError(.unauthenticated, "x")).fatal)
        XCTAssertFalse(ErrorPayload(ProtocolError(.rateLimited, "x")).fatal)
    }

    func testAllClientEventTypesRoundTripTheirRawValue() {
        for type in ClientEventType.allCases {
            XCTAssertEqual(ClientEventType(rawValue: type.rawValue), type)
        }
    }
}
