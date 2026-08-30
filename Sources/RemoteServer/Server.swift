import Foundation
import Network
import RemoteKit

/// The TLS listener, plus ownership of which connection currently holds the pointer.
///
/// Binds only to private addresses. Advertises `_airpoint._tcp` over Bonjour so a native
/// client can find the Mac without the user reading an IP address aloud.
public final class Server {

    private let config: ServerConfig
    private let handler: RemoteSessionHandler
    private let pairing: PairingService
    private let identity: TLSIdentity.Loaded
    private let originPolicy: OriginPolicy
    let staticFiles: StaticFiles

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.airpoint.server")
    private let pathMonitor = NWPathMonitor()

    /// Every live connection, authenticated or not.
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    /// Authenticated connections, oldest first. Bounded by `maxConcurrentSessions`.
    private var activeSessions: [ObjectIdentifier] = []

    public let subjectNames: [String]

    public init(config: ServerConfig, handler: RemoteSessionHandler, pairing: PairingService,
                identity: TLSIdentity.Loaded, subjectNames: [String]) {
        self.config = config
        self.handler = handler
        self.pairing = pairing
        self.identity = identity
        self.subjectNames = subjectNames
        self.originPolicy = OriginPolicy(subjectNames: subjectNames, port: config.port)
        self.staticFiles = StaticFiles(content: config.staticContent)
    }

    public enum ServerError: Error, CustomStringConvertible {
        case invalidPort(UInt16)
        case publicBindRefused(String)
        case listenFailed(String)

        public var description: String {
            switch self {
            case .invalidPort(let port): return "port \(port) is not usable"
            case .publicBindRefused(let host):
                return """
                refusing to bind '\(host)': it is not a private address. AirPoint is a
                local-network tool and does not expose input control to the internet.
                Pass --i-know-what-im-doing to override.
                """
            case .listenFailed(let detail): return "could not start listening: \(detail)"
            }
        }
    }

    public func start() throws {
        if let host = config.bindHost, !config.allowPublicBind {
            let isIPv4 = host.contains(".")
            guard host == "localhost" || NetworkInterfaces.isPrivateAddress(host, isIPv4: isIPv4) else {
                throw ServerError.publicBindRefused(host)
            }
        }
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            throw ServerError.invalidPort(config.port)
        }

        let parameters = NWParameters(tls: TLSIdentity.tlsOptions(for: identity.identity),
                                      tcp: Self.tcpOptions())
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let host = config.bindHost {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        }

        let listener: NWListener
        do {
            // When a specific interface is requested, the port travels inside
            // requiredLocalEndpoint; passing it again via `on:` is rejected with EINVAL.
            listener = config.bindHost == nil
                ? try NWListener(using: parameters, on: port)
                : try NWListener(using: parameters)
        } catch {
            throw ServerError.listenFailed(String(describing: error))
        }

        listener.service = NWListener.Service(name: config.serviceName, type: config.serviceType)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Log.info("listening on port \(self?.config.port ?? 0) (TLS)")
            case .failed(let error):
                // The overwhelmingly common cause is the macOS firewall blocking the bind,
                // so say so rather than printing a bare POSIX error.
                Log.error("listener failed: \(error). If macOS asked whether to allow incoming connections, choose Allow; otherwise check System Settings > Network > Firewall.")
            case .cancelled:
                Log.info("listener stopped")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)
        self.listener = listener
        startPathMonitoring()
    }

    private static func tcpOptions() -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        // Motion deltas are tiny and latency-critical; Nagle would coalesce them into
        // visible stutter.
        options.noDelay = true
        options.connectionTimeout = 10
        options.enableKeepalive = true
        options.keepaliveIdle = 5
        return options
    }

    /// Warns when the machine's addresses change, because the certificate SANs and the
    /// QR code are now stale.
    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let current = Set(NetworkInterfaces.privateIPv4Addresses())
            let known = Set(self.subjectNames)
            if path.status == .satisfied && !current.isSubset(of: known) {
                Log.warn("this Mac's LAN address changed to \(current.sorted().joined(separator: ", ")); restart airpointd so the certificate and QR code match")
            }
        }
        pathMonitor.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.close(code: .goingAway, reason: "server stopping")
            }
            connections.removeAll()
            activeSessions.removeAll()
        }
        pathMonitor.cancel()
    }

    /// Immediate revocation of all control. Wired to the panic path.
    public func disconnectAll(reason: String) {
        queue.sync {
            for connection in connections.values {
                connection.close(code: .policyViolation, reason: reason)
            }
            connections.removeAll()
            activeSessions.removeAll()
        }
        Log.warn("all sessions disconnected: \(reason)")
    }

    public var connectedDeviceNames: [String] {
        queue.sync { activeSessions.compactMap { connections[$0]?.deviceName } }
    }

    // MARK: - Connection lifecycle

    private func accept(_ nwConnection: NWConnection) {
        let client = ClientConnection(connection: nwConnection,
                                      handler: handler,
                                      pairing: pairing,
                                      originPolicy: originPolicy,
                                      config: config,
                                      server: self)
        queue.async {
            self.connections[ObjectIdentifier(client)] = client
            client.start()
        }
    }

    func remove(_ client: ClientConnection) {
        queue.async {
            let key = ObjectIdentifier(client)
            self.connections.removeValue(forKey: key)
            if let index = self.activeSessions.firstIndex(of: key) {
                self.activeSessions.remove(at: index)
                Log.info("session ended (\(self.activeSessions.count) still active)")
            }
        }
    }

    /// Admits a newly authenticated session, evicting the oldest if the seat limit is full.
    ///
    /// With `maxConcurrentSessions == 1` this reproduces AirPoint's rule exactly: a second
    /// approved device takes over rather than fighting for the cursor. With a larger limit
    /// every device keeps its own session, which is what a multiplayer host wants.
    func admit(_ client: ClientConnection) {
        queue.async {
            let key = ObjectIdentifier(client)
            guard !self.activeSessions.contains(key) else { return }

            while self.activeSessions.count >= max(self.config.maxConcurrentSessions, 1) {
                let oldest = self.activeSessions.removeFirst()
                guard let evicted = self.connections[oldest] else { continue }
                Log.info("'\(client.deviceName ?? "device")' took the seat held by '\(evicted.deviceName ?? "device")'")
                evicted.sendError(ProtocolError(.sessionReplaced, "another device took control"))
                evicted.close(code: .policyViolation, reason: "replaced")
            }
            self.activeSessions.append(key)
        }
    }

    func isAdmitted(_ client: ClientConnection) -> Bool {
        queue.sync { activeSessions.contains(ObjectIdentifier(client)) }
    }
}
