import Foundation
import Network
import RemoteKit

/// One client connection: HTTP first, then (optionally) a WebSocket control session.
///
/// The state machine is deliberately strict. A connection starts unauthenticated, may send
/// only `hello`/`ping`/`disconnect`, and has a hard deadline to authenticate. Every inbound
/// frame is size-checked, decoded, validated and rate-limited before it can reach the
/// executor — in that order, so an expensive step never runs on unvalidated input.
final class ClientConnection: RemoteSession {

    private enum Phase {
        case awaitingHTTP
        case unauthenticated
        case authenticated
        /// Final bytes are still flushing. No further inbound frames are processed, but the
        /// socket stays open long enough for the peer to actually receive them.
        case closing
        case closed
    }

    private let connection: NWConnection
    private let handler: RemoteSessionHandler
    private let pairing: PairingService
    private let originPolicy: OriginPolicy
    private let config: ServerConfig
    private weak var server: Server?

    private let queue = DispatchQueue(label: "com.airpoint.connection")
    private var phase: Phase = .awaitingHTTP
    private var buffer = Data()
    private var assembler = WebSocket.MessageAssembler()

    private let nonce = Nonce.generate()
    private var limiter: SessionRateLimiter
    private var outboundSeq: UInt32 = 0
    private var lastAppliedPointerSeq: UInt32 = 0
    private var malformedFrames = 0
    private var rejectedFrames = 0
    private var lastRateLimitNoticeAt: [ClientEventType: Date] = [:]

    // Motion telemetry. The useful diagnostic is not "how many packets" but "did any motion
    // ever arrive": a phone whose sensors are blocked connects, pairs and clicks perfectly
    // while the cursor never moves, and that looks identical to a broken server.
    private var pointerFrameCount = 0
    private var pointerPixelsMoved = 0.0
    private var pointerMaxDelta = 0.0
    private var lastMotionReportAt = Date()
    private var framesSinceReport = 0
    private var pixelsSinceReport = 0.0
    private var authenticatedAt: Date?
    private var announcedMotion = false
    private var warnedAboutMissingMotion = false
    private var lastInboundAt = Date()
    private var sessionExpiresAt = Date().addingTimeInterval(Limits.sessionLifetime)
    private var timer: DispatchSourceTimer?

    let id = UUID()
    private(set) var deviceName: String?
    let peer: String

    init(connection: NWConnection, handler: RemoteSessionHandler, pairing: PairingService,
         originPolicy: OriginPolicy, config: ServerConfig, server: Server) {
        self.connection = connection
        self.handler = handler
        self.pairing = pairing
        self.originPolicy = originPolicy
        self.config = config
        self.server = server
        self.peer = Self.describe(connection.endpoint)
        self.limiter = SessionRateLimiter(now: Date().timeIntervalSince1970)
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            // Drop the interface suffix from link-local IPv6 so the string is stable
            // as a rate-limiting key.
            return String(describing: host).components(separatedBy: "%").first ?? String(describing: host)
        default:
            return String(describing: endpoint)
        }
    }

    // MARK: - Lifecycle

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Log.debug("connection ready from \(self?.peer ?? "?")")
                self?.receive()
            case .failed(let error):
                Log.debug("connection failed from \(self?.peer ?? "?"): \(error)")
                self?.teardown()
            case .cancelled:
                self?.teardown()
            default:
                break
            }
        }
        connection.start(queue: queue)
        startWatchdog()
    }

    /// One timer covers three deadlines: the authentication deadline, the idle timeout,
    /// and the hard session lifetime.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            switch self.phase {
            case .awaitingHTTP, .unauthenticated:
                if now.timeIntervalSince(self.lastInboundAt) > Limits.helloDeadline {
                    Log.debug("closing \(self.peer): no authentication within \(Int(Limits.helloDeadline))s")
                    self.sendError(ProtocolError(.unauthenticated, "authentication deadline exceeded"))
                    self.close(code: .policyViolation, reason: "auth timeout")
                }
            case .authenticated:
                self.warnIfNoMotion(now: now)
                if now.timeIntervalSince(self.lastInboundAt) > Limits.idleTimeout {
                    Log.info("closing idle session with '\(self.deviceName ?? "device")'")
                    self.close(code: .goingAway, reason: "idle")
                } else if now > self.sessionExpiresAt {
                    self.sendError(ProtocolError(.sessionExpired, "session lifetime reached; pair again"))
                    self.close(code: .policyViolation, reason: "expired")
                }
            case .closing, .closed:
                break
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Log.debug("receive error from \(self.peer): \(error)")
                self.teardown()
                return
            }
            if let data, !data.isEmpty {
                self.lastInboundAt = Date()
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete {
                self.teardown()
                return
            }
            guard self.phase != .closed else { return }
            self.receive()
        }
    }

    private func drainBuffer() {
        switch phase {
        case .awaitingHTTP:
            handleHTTPPhase()
        case .unauthenticated, .authenticated:
            handleWebSocketPhase()
        case .closing, .closed:
            buffer.removeAll()
        }
    }

    // MARK: - HTTP phase

    private func handleHTTPPhase() {
        let parsed: (request: HTTPRequest, headLength: Int)?
        do {
            parsed = try HTTPRequest.parse(buffer)
        } catch {
            Log.debug("bad HTTP request from \(peer): \(error)")
            sendRaw(StaticFiles.errorResponse(status: 400, reason: "Bad Request", message: "malformed request"))
            close(code: .protocolError, reason: "bad http")
            return
        }
        guard let parsed else { return }   // head not complete yet
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + parsed.headLength))

        let request = parsed.request

        if case .reject(let reason) = originPolicy.evaluate(request) {
            // This is the anti-DNS-rebinding / anti-cross-origin path. Log it: an unexpected
            // hit here means something on the network is probing.
            Log.warn("refused request from \(peer): \(reason)")
            sendRaw(StaticFiles.errorResponse(status: 403, reason: "Forbidden",
                                              message: "This request was refused: \(reason)"))
            close(code: .policyViolation, reason: "origin policy")
            return
        }

        if request.isWebSocketUpgrade {
            completeUpgrade(request)
        } else {
            serveStatic(request)
        }
    }

    private func serveStatic(_ request: HTTPRequest) {
        guard request.method == "GET" || request.method == "HEAD" else {
            sendRaw(StaticFiles.errorResponse(status: 405, reason: "Method Not Allowed", message: "GET only"))
            close(code: .normal, reason: "method")
            return
        }
        guard let asset = server?.staticFiles.asset(for: request.path) else {
            sendRaw(StaticFiles.errorResponse(status: 404, reason: "Not Found", message: "Not found"))
            close(code: .normal, reason: "404")
            return
        }
        let body = request.method == "HEAD" ? Data() : asset.data
        sendRaw(StaticFiles.response(status: 200, reason: "OK", body: body, contentType: asset.contentType))
        close(code: .normal, reason: "served")
    }

    private func completeUpgrade(_ request: HTTPRequest) {
        guard let key = request.header("sec-websocket-key"),
              request.header("sec-websocket-version") == "13" else {
            sendRaw(StaticFiles.errorResponse(status: 400, reason: "Bad Request",
                                              message: "unsupported WebSocket handshake"))
            close(code: .protocolError, reason: "bad handshake")
            return
        }
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(WebSocket.acceptKey(for: key))\r
        \r

        """
        sendRaw(Data(response.utf8))
        phase = .unauthenticated
        lastInboundAt = Date()
        Log.debug("websocket upgraded for \(peer)")

        // The challenge nonce goes out immediately; the client's proof must be computed
        // over it, which is what makes a captured `hello` useless on a later connection.
        send(.challenge, ChallengePayload(nonce: nonce.base64URLEncodedString(),
                                          serverVersion: config.serverVersion))
        // Any bytes that arrived in the same TCP segment as the handshake are already frames.
        if !buffer.isEmpty { handleWebSocketPhase() }
    }

    // MARK: - WebSocket phase

    private func handleWebSocketPhase() {
        while phase == .unauthenticated || phase == .authenticated {
            let frame: WebSocket.Frame?
            do {
                frame = try WebSocket.decodeFrame(from: &buffer)
            } catch {
                Log.warn("framing error from \(peer): \(error)")
                close(code: .protocolError, reason: "framing")
                return
            }
            guard let frame else { return }

            let message: (opcode: WebSocket.Opcode, payload: Data)?
            do {
                message = try assembler.accept(frame)
            } catch {
                Log.warn("message assembly error from \(peer): \(error)")
                close(code: .messageTooBig, reason: "message too large")
                return
            }
            guard let message else { continue }

            switch message.opcode {
            case .text, .binary:
                handleMessage(message.payload)
            case .ping:
                sendRaw(WebSocket.encodeFrame(opcode: .pong, payload: message.payload))
            case .pong:
                break
            case .close:
                close(code: .normal, reason: "client closed")
                return
            case .continuation:
                break
            }
        }
    }

    private func handleMessage(_ data: Data) {
        let message: ClientMessage
        do {
            message = try ClientMessage.decode(data).validated()
            malformedFrames = 0
            rejectedFrames = 0
        } catch let error as ProtocolError {
            handleProtocolError(error)
            return
        } catch {
            handleProtocolError(ProtocolError(.badJSON, "unparseable frame"))
            return
        }

        let now = Date().timeIntervalSince1970
        if let limitError = limiter.allow(message.event.type, now: now) {
            // Dropped, never queued: a queued motion delta is stale by the time it lands,
            // and a queued click is an input the user never asked for.
            //
            // The notice is throttled separately. Replying to every dropped frame turns a
            // flood of N inbound messages into N outbound ones, which amplifies the load we
            // are trying to shed — the opposite of what a rate limiter is for. One notice
            // per type per second is enough for a client to notice and back off.
            noteRateLimited(message.event.type, error: limitError)
            return
        }

        guard phase == .authenticated || message.event.allowedBeforeAuth else {
            sendError(ProtocolError(.unauthenticated, "authenticate with hello first"))
            close(code: .policyViolation, reason: "unauthenticated")
            return
        }

        dispatch(message)
    }

    /// Frames rejected before decoding never reach the rate limiter, so they get their own
    /// budget. Without it, a client could flood invalid frames indefinitely at no cost.
    /// Reports what the deltas actually look like, not merely that some arrived.
    ///
    /// "Motion is flowing" is nearly useless on its own: a phone dribbling 0.05 px per frame
    /// satisfies it while the cursor visibly never moves. The magnitudes are the diagnosis —
    /// they separate "the sensors are barely changing" from "the deltas are fine and the
    /// problem is further down".
    private func reportMotionRate() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastMotionReportAt)
        guard elapsed >= 2, framesSinceReport > 0 else { return }
        let rate = Double(framesSinceReport) / elapsed
        let mean = pixelsSinceReport / Double(framesSinceReport)
        Log.info(String(format: "pointer: %.0f frames/s, mean %.2f px/frame, peak %.1f px, %.0f px total",
                        rate, mean, pointerMaxDelta, pointerPixelsMoved))
        if mean < 0.3 {
            Log.warn("""
            those deltas are far too small to see (mean \(String(format: "%.2f", mean)) px/frame).             Either the phone is barely moving, or the pad is only being touched briefly — motion             runs only while the pad is held. Tap "Aim: hold the pad" on the phone to lock it on.
            """)
        }
        lastMotionReportAt = now
        framesSinceReport = 0
        pixelsSinceReport = 0
    }

    /// A session that is alive and sending frames but has never sent a pointer delta means
    /// the phone's sensors are not reaching the page. Saying so beats leaving the user to
    /// wonder whether the Mac, the network or the phone is at fault.
    private func warnIfNoMotion(now: Date) {
        guard !warnedAboutMissingMotion, !announcedMotion,
              let since = authenticatedAt, now.timeIntervalSince(since) > 15 else { return }
        warnedAboutMissingMotion = true
        Log.warn("""
        connected to '\(deviceName ?? "device")' for 15s but no cursor motion has arrived.         Other controls will still work. On the phone: check the page is on https://, that you         tapped "Enable motion" and allowed the prompt, and that you are holding a finger on         the pad — motion is only live while the pad is held.
        """)
    }

    private func logCalibration(_ payload: CalibrationPayload) {
        func format(_ values: [Double]?) -> String {
            guard let values else { return "—" }
            return "(" + values.map { String(format: "%+.2f", $0) }.joined(separator: ", ") + ")"
        }
        if payload.stage == .sampling {
            Log.info("sensor: gravityDown=\(format(payload.gravity)) rate=\(format(payload.rate)) -> [yaw, pitch]=\(format(payload.resolved))")
        } else {
            Log.info("calibration \(payload.stage.rawValue) from '\(deviceName ?? "device")'")
        }
    }

    private func noteRateLimited(_ type: ClientEventType, error: ProtocolError) {
        let now = Date()
        if let last = lastRateLimitNoticeAt[type], now.timeIntervalSince(last) < 1 { return }
        lastRateLimitNoticeAt[type] = now
        sendError(error)
    }

    private func handleProtocolError(_ error: ProtocolError) {
        rejectedFrames += 1
        if error.code == .badJSON { malformedFrames += 1 }
        sendError(error)

        if error.code.isFatal {
            close(code: .policyViolation, reason: error.code.rawValue)
        } else if malformedFrames >= Limits.maxMalformedFrames {
            Log.warn("closing \(peer) after \(malformedFrames) frames that were not valid JSON")
            close(code: .protocolError, reason: "malformed frames")
        } else if rejectedFrames >= Limits.maxRejectedFrames {
            Log.warn("closing \(peer) after \(rejectedFrames) consecutive rejected frames")
            close(code: .policyViolation, reason: "too many rejected frames")
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ message: ClientMessage) {
        switch message.event {
        // Session-level concerns stay here; they are about the connection, not about what
        // the events mean, and a host application should not have to reimplement them.
        case .hello(let hello):
            handleHello(hello)

        case .ping(let ping):
            send(.pong, PongPayload(id: ping.id, clientTs: message.ts))

        case .disconnect(let payload):
            Log.info("'\(deviceName ?? "device")' disconnected (\(payload.reason))")
            close(code: .normal, reason: payload.reason)

        case .pointerMove:
            // Stale deltas are worse than no deltas: applying an out-of-order motion frame
            // makes the cursor visibly stutter backwards.
            guard message.seq == 0 || message.seq >= lastAppliedPointerSeq else { return }
            lastAppliedPointerSeq = message.seq
            deliver(message.event)

        default:
            deliver(message.event)
        }
    }

    /// Passes a validated event to the host application, once it is entitled to act.
    private func deliver(_ event: ClientEvent) {
        guard let server, server.isAdmitted(self) else { return }
        guard handler.isReady(for: self) else {
            // Refused visibly rather than silently dropped: a remote that does nothing is
            // indistinguishable from a broken one.
            sendError(ProtocolError(.permissionDenied, "the host cannot accept input right now"))
            return
        }
        if case .pointerMove(let move) = event {
            pointerFrameCount += 1
            let magnitude = (move.dx * move.dx + move.dy * move.dy).squareRoot()
            pointerPixelsMoved += magnitude
            pointerMaxDelta = max(pointerMaxDelta, magnitude)
            framesSinceReport += 1
            pixelsSinceReport += magnitude
            announcedMotion = true
            reportMotionRate()
        }
        if case .calibration(let calibration) = event {
            logCalibration(calibration)
        }
        handler.handle(event, from: self)
    }

    private func handleHello(_ hello: HelloPayload) {
        guard phase == .unauthenticated else {
            sendError(ProtocolError.invalid("hello was already sent"))
            return
        }
        deviceName = hello.deviceName
        Log.info("pairing request from '\(hello.deviceName)' (\(peer)) mode=\(hello.auth.mode.rawValue) client=\(hello.clientVersion)")

        // A reconnecting WebSocket does not reload the page, so a tab left open across an
        // update keeps running the old controller indefinitely while looking healthy.
        if hello.clientVersion != config.expectedClientVersion {
            Log.warn("""
            this phone is running controller \(hello.clientVersion) but this server ships             \(config.expectedClientVersion). The page did not reload. Close the tab on the phone             entirely and open the URL again — reconnecting over WebSocket does not fetch new code.
            """)
        }

        if hello.auth.mode == .code {
            send(.pairPending, PairPendingPayload(message: "Approve this device on your Mac",
                                                  timeoutMs: Int(Limits.pairingApprovalTimeout * 1000)))
        }

        pairing.authenticate(hello: hello, nonce: nonce, peer: peer) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                guard self.phase == .unauthenticated else { return }
                switch outcome {
                case .rejected(let error):
                    self.sendError(error)
                    self.close(code: .policyViolation, reason: error.code.rawValue)
                case .paired(let name, _):
                    self.deviceName = name
                    self.completeAuthentication()
                case .resumed(let device):
                    self.deviceName = device.deviceName
                    self.completeAuthentication()
                }
            }
        }
    }

    private func completeAuthentication() {
        phase = .authenticated
        authenticatedAt = Date()
        sessionExpiresAt = Date().addingTimeInterval(Limits.sessionLifetime)
        server?.admit(self)

        send(.welcome, WelcomePayload(
            sessionId: id.uuidString,
            expiresAt: Int64(sessionExpiresAt.timeIntervalSince1970 * 1000),
            displays: handler.displays(for: self),
            features: handler.features(for: self),
            permissions: handler.permissions(for: self)
        ))
        handler.sessionDidBegin(self)
        Log.info("session established with '\(deviceName ?? "device")'")
    }

    // MARK: - Sending

    private func nextSeq() -> UInt32 {
        outboundSeq &+= 1
        return outboundSeq
    }

    private func send<P: Encodable>(_ type: ServerEventType, _ payload: P) {
        do {
            let data = try ServerEnvelope(type: type, seq: nextSeq(), payload: payload).encoded()
            sendRaw(WebSocket.encodeFrame(opcode: .text, payload: data))
        } catch {
            Log.error("could not encode a \(type.rawValue) frame: \(error)")
        }
    }

    func sendError(_ error: ProtocolError) {
        guard phase == .unauthenticated || phase == .authenticated else { return }
        send(.error, ErrorPayload(error))
    }

    // MARK: - RemoteSession

    func send(error: ProtocolError) { queue.async { self.sendError(error) } }

    func send(status: StatusPayload) {
        queue.async {
            guard self.phase == .authenticated else { return }
            self.send(.status, status)
        }
    }

    func send(focus: FocusPayload) {
        queue.async {
            guard self.phase == .authenticated else { return }
            self.send(.focus, focus)
        }
    }

    private func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                Log.debug("send failed: \(error)")
            }
        })
    }

    /// Closes the session, flushing anything already queued first.
    ///
    /// `NWConnection.cancel()` discards unsent data. Calling it immediately after writing an
    /// error frame means the peer is disconnected without ever learning why — it sees a bare
    /// TCP reset (close code 1006) instead of the explanation we just wrote. So the cancel
    /// waits for the final send to complete, with a timeout in case it never does.
    func close(code: WebSocket.CloseCode, reason: String) {
        queue.async { [weak self] in
            guard let self, self.phase != .closed, self.phase != .closing else { return }
            let shouldSendCloseFrame = self.phase == .unauthenticated || self.phase == .authenticated
            self.phase = .closing

            guard shouldSendCloseFrame else {
                self.flushThenTeardown()
                return
            }
            self.connection.send(
                content: WebSocket.encodeClose(code, reason: reason),
                completion: .contentProcessed { [weak self] _ in self?.teardown() }
            )
            // A peer that has stopped reading would otherwise hold the connection open.
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.teardown() }
        }
    }

    /// For the HTTP path, where the response body was already queued.
    private func flushThenTeardown() {
        connection.send(content: Data(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.teardown() })
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.teardown() }
    }

    private func teardown() {
        guard phase != .closed else { return }   // the flush completion and the timeout race
        phase = .closed
        timer?.cancel()
        timer = nil
        assembler.reset()
        buffer.removeAll()
        if pointerFrameCount > 0 {
            Log.info("session summary: \(pointerFrameCount) pointer frames, \(Int(pointerPixelsMoved)) px of travel")
        }
        connection.cancel()
        handler.sessionDidEnd(self)
        server?.remove(self)
    }
}
