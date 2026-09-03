import Foundation
import SwiftUI
import RemoteKit
import RemoteServer
import AirPointCore

/// Everything the menu-bar UI observes, and the only place the server is started or stopped.
///
/// The daemon and this app run the identical `AirPointCore` stack; the difference is that
/// approval happens in a sheet instead of on stdin, and the pairing code is on screen
/// instead of in a terminal.
@MainActor
final class AppModel: ObservableObject {

    enum Status: Equatable {
        case stopped
        case starting
        case listening
        case connected(String)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .listening, .connected: return true
            case .stopped, .starting, .failed: return false
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var pairingCode = ""
    @Published private(set) var pairingURL = ""
    @Published private(set) var codeSecondsRemaining = 0
    @Published private(set) var addresses: [String] = []
    @Published private(set) var trustedDevices: [TrustedDevice] = []
    @Published private(set) var hasAccessibility = false
    @Published private(set) var firewall: FirewallState = .unknown
    @Published private(set) var recentIssues: [LogBuffer.Entry] = []
    @Published var pendingRequest: PairingRequest?

    /// A device waiting on a human. Kept in the model rather than passed to a window, so the
    /// UI can show it wherever it likes and a decision can be forced on quit.
    struct PairingRequest: Identifiable, Equatable {
        let id = UUID()
        let deviceName: String
        let peer: String
        let decide: (PairingDecision) -> Void

        static func == (lhs: PairingRequest, rhs: PairingRequest) -> Bool { lhs.id == rhs.id }
    }

    private var server: Server?
    private var pairing: PairingService?
    private var trustStore: TrustStore?
    private let executor = CGEventExecutor()
    private var handler: PointerHandler?
    /// Kept so a regenerated code still carries the certificate pin. Rebuilding the URL
    /// without it silently downgrades every QR scan to the unpinned typed-code path.
    private var certificateFingerprint = ""
    private var approver: UIApprover?
    private var ticker: Timer?
    private var panicHotKey: PanicHotKey?
    /// Warnings and errors, captured for the troubleshooting panel. The buffer taps the
    /// one logging path rather than adding a second, so redaction still applies.
    private let issueLog = LogBuffer(capacity: 50, keeping: .warn)

    private static let port: UInt16 = 8443

    private let stateDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AirPoint", isDirectory: true)
    }()

    init() {
        issueLog.installAsTap()
        refreshPermission()
        // Launching is the user saying they want this running. Making them click Start as
        // well would be a step that exists only because the code was easier to write that
        // way. It listens; nothing can control the Mac until a human approves a device.
        Task { @MainActor in self.start() }
    }

    // MARK: - Lifecycle

    func start() {
        guard !status.isRunning else { return }
        status = .starting

        var subjectNames = NetworkInterfaces.privateIPv4Addresses()
        if let localName = NetworkInterfaces.localHostName() { subjectNames.append(localName) }
        subjectNames.append(contentsOf: ["localhost", "127.0.0.1"])
        subjectNames = Array(NSOrderedSet(array: subjectNames)) as? [String] ?? subjectNames

        guard !NetworkInterfaces.privateIPv4Addresses().isEmpty else {
            status = .failed("This Mac is not on a network your phone can reach. "
                             + "Join the same Wi-Fi network and try again.")
            return
        }

        do {
            let tlsSecrets = try SecretStoreFactory.make(useKeychain: false,
                                                        stateDirectory: stateDirectory,
                                                        service: "com.airpoint", purpose: "tls")
            let deviceSecrets = try SecretStoreFactory.make(useKeychain: false,
                                                           stateDirectory: stateDirectory,
                                                           service: "com.airpoint", purpose: "devices")
            let identity = try TLSIdentity.loadOrCreate(stateDirectory: stateDirectory,
                                                       subjectNames: subjectNames,
                                                       secrets: tlsSecrets)

            let approver = UIApprover { [weak self] request in
                self?.pendingRequest = request
            }
            let trustStore = TrustStore(secrets: deviceSecrets)
            let pairing = PairingService(trustStore: trustStore, approver: approver)
            let handler = PointerHandler(executor: executor, dryRun: false, focusDetection: true)

            let config = ServerConfig(
                port: Self.port,
                stateDirectory: stateDirectory,
                serviceName: "AirPoint on \(ProcessInfo.processInfo.hostName)",
                serviceType: "_airpoint._tcp",
                serverVersion: AirPoint.version,
                expectedClientVersion: AirPoint.controllerVersion,
                maxConcurrentSessions: 1,
                staticContent: .airPointController
            )

            let server = Server(config: config, handler: handler, pairing: pairing,
                                identity: identity, subjectNames: subjectNames)
            try server.start()

            self.approver = approver
            self.trustStore = trustStore
            self.pairing = pairing
            self.handler = handler
            self.server = server
            self.addresses = subjectNames.filter { $0 != "localhost" && $0 != "127.0.0.1" }

            certificateFingerprint = identity.certificateFingerprint
            show(pairing.currentSecret())
            status = .listening
            refreshTrustedDevices()
            refreshFirewall()
            startTicking()
            // The panic path must outlive a hostile or broken session, so it is global:
            // ⌃⌥⌘⎋ works with any app focused. Held only while there is a server whose
            // sessions it could kill.
            panicHotKey = PanicHotKey { [weak self] in self?.panic() }
        } catch {
            // Into the log as well as onto the panel, so the failure is still visible in
            // the troubleshooting section after the user clicks past it.
            Log.error("start failed: \(String(describing: error))")
            status = .failed(String(describing: error))
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        // Deny anything outstanding rather than leaving a phone waiting on a decision that
        // will never come.
        pendingRequest?.decide(.deny)
        pendingRequest = nil
        panicHotKey = nil
        server?.stop()
        server = nil
        pairing = nil
        status = .stopped
        pairingCode = ""
    }

    /// Kills every session and releases anything held. The one control that must always work.
    func panic() {
        server?.disconnectAll(reason: "disconnected by the user")
        executor.releaseAll()
        pendingRequest?.decide(.deny)
        pendingRequest = nil
        refreshStatus()
    }

    func newPairingCode() {
        guard let pairing else { return }
        show(pairing.rotateSecret())
        codeSecondsRemaining = pairing.remainingCodeSeconds()
    }

    /// The one place a code becomes what is on screen. The URL must always be rebuilt
    /// alongside the code and always with the certificate pin — building it anywhere
    /// else is how a QR scan silently downgrades to the unpinned typed-code path.
    private func show(_ secret: PairingSecret) {
        pairingCode = secret.displayCode
        pairingURL = secret.pairingURL(host: server?.subjectNames.first ?? "127.0.0.1",
                                       port: Self.port,
                                       fingerprint: certificateFingerprint)
    }

    // MARK: - Permission

    func refreshPermission() {
        hasAccessibility = executor.hasPermission
    }

    /// Raises the system prompt. Its real value is registering the binary in System Settings
    /// so the user gets a checkbox rather than having to find a path.
    func requestAccessibility() {
        executor.requestPermission()
        // The permission cannot take effect until the switch is flipped, so poll rather than
        // asking the user to relaunch and hope.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.refreshPermission()
                if self.hasAccessibility { timer.invalidate() }
            }
        }
    }

    // MARK: - Trust

    func refreshTrustedDevices() {
        trustedDevices = trustStore?.all().sorted { $0.lastSeenAt > $1.lastSeenAt } ?? []
    }

    func revoke(_ device: TrustedDevice) {
        trustStore?.revoke(deviceId: device.deviceId)
        refreshTrustedDevices()
    }

    func revokeAll() {
        trustStore?.revokeAll()
        refreshTrustedDevices()
    }

    func decide(_ decision: PairingDecision) {
        pendingRequest?.decide(decision)
        pendingRequest = nil
        if decision == .approveAndTrust { refreshTrustedDevices() }
    }

    // MARK: - Polling

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private func refreshStatus() {
        guard let server, status.isRunning else { return }
        refreshPermission()
        recentIssues = issueLog.recent
        codeSecondsRemaining = pairing?.remainingCodeSeconds() ?? 0
        if let name = server.connectedDeviceNames.first {
            status = .connected(name)
        } else {
            status = .listening
            // A consumed or expired code is useless on screen; show the live one.
            if let secret = pairing?.currentSecret(), secret.displayCode != pairingCode {
                show(secret)
            }
        }
    }

    // MARK: - Troubleshooting

    /// Probed rather than watched: the firewall changes when a human flips it in System
    /// Settings, so refreshing when the panel is opened is both sufficient and honest
    /// about staleness. Probing spawns a process, hence off the main actor.
    func refreshFirewall() {
        Task.detached(priority: .utility) {
            let state = FirewallState.probe()
            await MainActor.run { self.firewall = state }
        }
    }
}

/// Routes approval requests to the UI.
private final class UIApprover: PairingApprover {
    private let present: (AppModel.PairingRequest) -> Void

    init(present: @escaping (AppModel.PairingRequest) -> Void) {
        self.present = present
    }

    func requestApproval(deviceName: String, peer: String,
                         completion: @escaping (PairingDecision) -> Void) {
        // Arrives on a connection queue; the UI must be touched on the main actor.
        Task { @MainActor in
            self.present(AppModel.PairingRequest(deviceName: deviceName, peer: peer,
                                                 decide: completion))
        }
    }
}
