import Foundation
import CoreGraphics
import RemoteKit

// MARK: - Startup

/// Held for the process lifetime; a `DispatchSourceSignal` stops firing if it is deallocated.
var signalSources: [DispatchSourceSignal] = []

let config: Config
do {
    config = try Config.load()
} catch {
    FileHandle.standardError.write(Data("airpointd: \(error)\n\n\(Config.usage)\n".utf8))
    exit(2)
}
Log.minimumLevel = config.logLevel

let executor: InputExecutor = config.dryRun ? RecordingExecutor() : CGEventExecutor()

if config.selfTest {
    exit(runSelfTest(executor: executor))
}

// The certificate must name every address the phone might use to reach us, or the browser
// shows a name mismatch on top of the self-signed warning and the user gives up.
var subjectNames = NetworkInterfaces.privateIPv4Addresses()
if let localName = NetworkInterfaces.localHostName() { subjectNames.append(localName) }
subjectNames.append("localhost")
subjectNames.append("127.0.0.1")
subjectNames = Array(NSOrderedSet(array: subjectNames)) as? [String] ?? subjectNames

guard subjectNames.count > 2 else {
    Log.error("no private network interface found. Connect this Mac to the same Wi-Fi network as your phone and try again.")
    exit(1)
}

let tlsSecrets: SecretStore
let deviceSecrets: SecretStore
do {
    tlsSecrets = try SecretStoreFactory.make(config: config, purpose: "tls")
    deviceSecrets = try SecretStoreFactory.make(config: config, purpose: "devices")
} catch {
    Log.error("\(error)")
    exit(1)
}
Log.debug("secrets stored in \(tlsSecrets.describeLocation)")

let identity: TLSIdentity.Loaded
do {
    identity = try TLSIdentity.loadOrCreate(stateDirectory: config.stateDirectory,
                                            subjectNames: subjectNames,
                                            secrets: tlsSecrets)
} catch {
    Log.error("\(error)")
    exit(1)
}

let trustStore = TrustStore(secrets: deviceSecrets)
let approver = ConsoleApprover(autoApprove: config.autoApprovePairing)
let pairing = PairingService(trustStore: trustStore, approver: approver)
let server = Server(config: config, executor: executor, pairing: pairing,
                    identity: identity, subjectNames: subjectNames)

do {
    try server.start()
} catch {
    Log.error("\(error)")
    exit(1)
}

printConnectionBanner(config: config, identity: identity, pairing: pairing,
                      subjectNames: subjectNames, executor: executor)

// A code printed once goes stale while the user is still tapping through the certificate
// warning, and the resulting failure looks like "wrong code" rather than "expired". Reprint
// whenever it rotates, so whatever is on screen is always usable.
var lastPrintedCode = pairing.currentSecret().displayCode
let codeWatcher = DispatchSource.makeTimerSource(queue: .global())
codeWatcher.schedule(deadline: .now() + 5, repeating: 5)
codeWatcher.setEventHandler {
    guard server.connectedDeviceName == nil else { return }
    let secret = pairing.currentSecret()
    guard secret.displayCode != lastPrintedCode else { return }
    lastPrintedCode = secret.displayCode
    printPairingCode(config: config, identity: identity, secret: secret, subjectNames: subjectNames)
}
codeWatcher.resume()

// MARK: - Signals

// Ctrl-C must release anything held. A stuck mouse button surviving the daemon would leave
// the Mac in a state the user cannot easily diagnose.
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        Log.info("shutting down")
        server.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()

// MARK: - Helpers

func printConnectionBanner(config: Config, identity: TLSIdentity.Loaded,
                           pairing: PairingService, subjectNames: [String],
                           executor: InputExecutor) {
    let secret = pairing.currentSecret()
    let primaryHost = subjectNames.first ?? "127.0.0.1"
    let url = secret.pairingURL(host: primaryHost, port: config.port,
                                fingerprint: identity.certificateFingerprint)

    var banner = """

    ┌─────────────────────────────────────────────────────────────────┐
    │  AirPoint \(AirPoint.version.padding(toLength: 53, withPad: " ", startingAt: 0))│
    └─────────────────────────────────────────────────────────────────┘

    On your phone, open:

        https://\(primaryHost):\(config.port)

    Pairing code:  \(secret.displayCode)   (valid \(secret.remainingSeconds())s)

    """

    if let qr = QRCode.terminalString(for: url) {
        banner += "Or scan:\n\n\(qr)\n\n"
    }

    banner += """
    Also reachable at: \(subjectNames.dropFirst().joined(separator: ", "))

    FIRST TIME:
      1. Safari will warn that the certificate is not trusted. This is expected —
         AirPoint signs its own certificate because it runs on your machine, not a
         public server. Tap Show Details, then "visit this website".
         Motion sensors do not work over plain HTTP, which is why TLS is required.
      2. Tap "Enable motion" and allow the sensor prompt.
      3. Approve the pairing request in this terminal.

    """

    if !executor.hasPermission && !config.dryRun {
        banner += """
        ⚠  ACCESSIBILITY PERMISSION IS NOT GRANTED.
           Clicks and cursor movement will not work until you add this binary in
           System Settings ▸ Privacy & Security ▸ Accessibility, then restart airpointd.
           Run `airpointd --selftest` to check.

        """
    }
    if config.dryRun {
        banner += "ℹ  --dry-run: connections are accepted but no real input is posted.\n\n"
    }

    FileHandle.standardError.write(Data(banner.utf8))
}

/// Reprints just the code and QR, without the full first-run banner.
func printPairingCode(config: Config, identity: TLSIdentity.Loaded,
                      secret: PairingSecret, subjectNames: [String]) {
    let host = subjectNames.first ?? "127.0.0.1"
    let url = secret.pairingURL(host: host, port: config.port,
                                fingerprint: identity.certificateFingerprint)
    // Scrollback now holds more than one QR code, and the stale one is the one that is
    // easier to scroll to. Say plainly which is which, or the user scans the old one and
    // gets a pairing failure that looks like a bug.
    var out = "\n"
    out += "════════════════════════════════════════════════════════════\n"
    out += "  The code above has EXPIRED. Ignore any earlier QR code.\n"
    out += "  Scan THIS one, or type THIS code:\n"
    out += "════════════════════════════════════════════════════════════\n\n"
    out += "    https://\(host):\(config.port)\n\n"
    out += "    Pairing code:  \(secret.displayCode)   (valid \(secret.remainingSeconds())s)\n\n"
    if let qr = QRCode.terminalString(for: url) { out += qr + "\n" }
    FileHandle.standardError.write(Data(out.utf8))
}

/// Moves the cursor in a square and reports whether it actually moved.
///
/// This is the fastest way to answer the single most common setup question: "is the
/// Accessibility permission actually working?" It exercises the real `CGEvent` path rather
/// than just calling `AXIsProcessTrusted`, because the two can disagree after the
/// permission is toggled without a relaunch.
func runSelfTest(executor: InputExecutor) -> Int32 {
    print("AirPoint self-test")
    print("  Accessibility trusted: \(executor.hasPermission ? "yes" : "NO")")

    let displays = executor.displays()
    print("  Displays: \(displays.map { "\($0.w)x\($0.h)@\($0.scale)x\($0.main ? " (main)" : "")" }.joined(separator: ", "))")

    guard executor.hasPermission else {
        print("""

          Accessibility permission is missing, so no events can be posted.
          Asking macOS to show the permission prompt now…
        """)
        // The prompt's side effect is the useful part: it registers this binary in
        // System Settings, so the entry is there to switch on rather than having to
        // locate a path inside .build/ by hand.
        executor.requestPermission()
        print("""
          1. In the dialog, choose "Open System Settings".
          2. Turn on the switch next to "airpointd".
          3. Run this command again — macOS binds the permission to the exact binary,
             so it must be re-checked after every rebuild.

          Binary: \(CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "?")
        """)
        return 1
    }

    let start = CGEvent(source: nil)?.location ?? .zero
    print("  Cursor starts at (\(Int(start.x)), \(Int(start.y))). Drawing a square…")

    let side = 120.0
    let steps = 40
    let legs: [(Double, Double)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    for (dx, dy) in legs {
        for _ in 0..<steps {
            executor.moveCursor(dx: dx * side / Double(steps), dy: dy * side / Double(steps))
            usleep(6000)
        }
    }
    usleep(120_000)

    let end = CGEvent(source: nil)?.location ?? .zero
    let drift = ((end.x - start.x) * (end.x - start.x) + (end.y - start.y) * (end.y - start.y)).squareRoot()
    print("  Cursor ended at (\(Int(end.x)), \(Int(end.y))); closed the loop within \(Int(drift)) px.")

    if drift > 8 {
        print("\n  The cursor did not return to its starting point. That usually means it hit a")
        print("  screen edge during the test — harmless, but move the pointer to the middle of")
        print("  a display and run again for a clean result.")
    }
    print("\n  If you saw the cursor move, input is working.")

    // The square above is drawn with a 6 ms pause between moves, which is generous enough
    // to hide a read-back race. A real session delivers 60 deltas a second with no pause at
    // all, so replay that shape too: burst small deltas and check the cursor actually
    // travelled the distance it was asked to.
    print("\n  Burst test (60 Hz, no pauses — this is what a real session looks like)…")
    let burstStart = CGEvent(source: nil)?.location ?? .zero
    let perFrame = 4.0
    let frames = 50
    for _ in 0..<frames {
        executor.moveCursor(dx: perFrame, dy: 0)
    }
    usleep(400_000)
    let burstEnd = CGEvent(source: nil)?.location ?? .zero
    let travelled = burstEnd.x - burstStart.x
    let expected = perFrame * Double(frames)
    print(String(format: "    asked for %.0f px, cursor travelled %.0f px", expected, travelled))

    // Undo it so the cursor ends where it started.
    for _ in 0..<frames { executor.moveCursor(dx: -perFrame, dy: 0) }
    usleep(300_000)

    if travelled < expected * 0.9 {
        print("""
            ✗ The cursor did not keep up with a burst of deltas. Rapid moves are being
              lost, which in a real session looks like a cursor that twitches but never
              travels. This is a bug in the input executor, not in your setup.
        """)
        return 1
    }
    print("    ✓ burst movement is accurate")
    return 0
}
