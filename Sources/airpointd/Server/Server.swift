import Foundation
import Network
import RemoteKit

/// The TLS listener, plus ownership of which connection currently holds the pointer.
///
/// Binds only to private addresses. Advertises `_airpoint._tcp` over Bonjour so a native
/// client can find the Mac without the user reading an IP address aloud.
final class Server {

    private let config: Config
    private let executor: InputExecutor
    private let pairing: PairingService
    private let identity: TLSIdentity.Loaded
    private let originPolicy: OriginPolicy

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.airpoint.server")
    private let pathMonitor = NWPathMonitor()

    /// Every live connection, authenticated or not.
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    /// The one connection allowed to produce input.
    private weak var pointerOwner: ClientConnection?

    let subjectNames: [String]

    init(config: Config, executor: InputExecutor, pairing: PairingService,
         identity: TLSIdentity.Loaded, subjectNames: [String]) {
        self.config = config
        self.executor = executor
        self.pairing = pairing
        self.identity = identity
        self.subjectNames = subjectNames
        self.originPolicy = OriginPolicy(subjectNames: subjectNames, port: config.port)
    }

    enum ServerError: Error, CustomStringConvertible {
        case invalidPort(UInt16)
        case publicBindRefused(String)
        case listenFailed(String)

        var description: String {
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

    func start() throws {
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

        listener.service = NWListener.Service(name: "AirPoint on \(ProcessInfo.processInfo.hostName)",
                                              type: "_airpoint._tcp")

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

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.close(code: .goingAway, reason: "server stopping")
            }
            connections.removeAll()
        }
        pathMonitor.cancel()
        executor.releaseAll()
    }

    /// Immediate revocation of all control. Wired to the panic path.
    func disconnectAll(reason: String) {
        queue.sync {
            for connection in connections.values {
                connection.close(code: .policyViolation, reason: reason)
            }
            connections.removeAll()
            pointerOwner = nil
        }
        executor.releaseAll()
        Log.warn("all sessions disconnected: \(reason)")
    }

    var connectedDeviceName: String? {
        queue.sync { pointerOwner?.deviceName }
    }

    // MARK: - Connection lifecycle

    private func accept(_ nwConnection: NWConnection) {
        let client = ClientConnection(connection: nwConnection,
                                      executor: executor,
                                      pairing: pairing,
                                      originPolicy: originPolicy,
                                      dryRun: config.dryRun,
                                      focusDetection: config.focusDetection,
                                      server: self)
        queue.async {
            self.connections[ObjectIdentifier(client)] = client
            client.start()
        }
    }

    func remove(_ client: ClientConnection) {
        queue.async {
            self.connections.removeValue(forKey: ObjectIdentifier(client))
            if self.pointerOwner === client {
                self.pointerOwner = nil
                // Whoever held the pointer may have left a button or modifier down.
                self.executor.releaseAll()
                Log.info("pointer session ended")
            }
        }
    }

    /// Grants pointer control, displacing any previous holder.
    /// Exactly one device can produce input at a time; a second approved device takes over
    /// rather than fighting for the cursor.
    func grantPointer(to client: ClientConnection) {
        queue.async {
            if let previous = self.pointerOwner, previous !== client {
                Log.info("'\(client.deviceName ?? "device")' took over from '\(previous.deviceName ?? "device")'")
                previous.sendError(ProtocolError(.sessionReplaced, "another device took control"))
                previous.close(code: .policyViolation, reason: "replaced")
                self.executor.releaseAll()
            }
            self.pointerOwner = client
        }
    }

    func holdsPointer(_ client: ClientConnection) -> Bool {
        queue.sync { pointerOwner === client }
    }
}
