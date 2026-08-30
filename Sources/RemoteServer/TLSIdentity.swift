import Foundation
import Security
import CryptoKit
import Network
import RemoteKit

/// Manages the daemon's self-signed TLS identity.
///
/// TLS is not optional here, and not only for confidentiality: `DeviceMotionEvent` is a
/// secure-context API in both Safari and Chrome, so a controller served over plain HTTP
/// can never read the gyroscope. Without TLS there is no product.
///
/// The certificate is generated on first run and regenerated whenever the machine's set of
/// LAN addresses changes, so the SAN list always matches the URL the phone will use. Its
/// SHA-256 fingerprint goes into the QR code; a native client pins it, which is what
/// upgrades a self-signed certificate from "encrypted but unauthenticated" to
/// "authenticated against the machine that drew the QR code" (threat T3).
public enum TLSIdentity {

    public struct Loaded {
        public let identity: SecIdentity
        public let certificateFingerprint: String   // base64url SHA-256 of the certificate DER
        public let subjectNames: [String]
    }

    public enum IdentityError: Error, CustomStringConvertible {
        case opensslMissing
        case opensslFailed(String)
        case importFailed(OSStatus)
        case noIdentityInBundle
        case missingPassword
        case keyUnusable
        case stateDirectoryFailed(String)

        public var description: String {
            switch self {
            case .opensslMissing:
                return "/usr/bin/openssl not found; cannot generate a TLS certificate"
            case .opensslFailed(let detail):
                return "certificate generation failed: \(detail)"
            case .importFailed(let status):
                return "could not import the PKCS#12 identity (OSStatus \(status))"
            case .noIdentityInBundle:
                return "the PKCS#12 bundle contained no identity"
            case .missingPassword:
                return "the stored TLS bundle password is missing or unreadable"
            case .keyUnusable:
                return "the stored private key could not be used to sign"
            case .stateDirectoryFailed(let detail):
                return "could not prepare the state directory: \(detail)"
            }
        }
    }

    private static let passwordAccount = "identity-p12-password"
    private static let certificateLabel = "AirPoint"

    /// Loads the existing identity, regenerating it if it is missing, expired, or no longer
    /// covers the current addresses.
    public static func loadOrCreate(stateDirectory: URL, subjectNames: [String],
                             secrets: SecretStore) throws -> Loaded {
        try prepareStateDirectory(stateDirectory)

        let bundleURL = stateDirectory.appendingPathComponent("identity.p12")
        let namesURL = stateDirectory.appendingPathComponent("identity.names")

        let previousNames = (try? String(contentsOf: namesURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []

        let needsRegeneration = !FileManager.default.fileExists(atPath: bundleURL.path)
            || Set(previousNames) != Set(subjectNames)

        if needsRegeneration {
            if !previousNames.isEmpty {
                Log.info("network addresses changed; regenerating the TLS certificate")
            }
            let password = try regenerate(at: bundleURL, subjectNames: subjectNames)
            try secrets.set(Data(password.utf8), account: passwordAccount)
            try subjectNames.joined(separator: "\n").write(to: namesURL, atomically: true, encoding: .utf8)
        }

        do {
            guard let stored = try secrets.get(account: passwordAccount),
                  let password = String(data: stored, encoding: .utf8) else {
                throw IdentityError.missingPassword
            }
            let loaded = try importIdentity(from: bundleURL, password: password, subjectNames: subjectNames)
            // Importing successfully is not proof that the key can be *used*: a key whose
            // keychain ACL no longer matches this binary imports fine and then blocks
            // forever inside the TLS handshake, with no error surfaced anywhere. Sign one
            // block here, under a timeout, so that failure becomes a regeneration instead
            // of a server that accepts connections and never answers them.
            guard keyIsUsable(loaded.identity) else { throw IdentityError.keyUnusable }
            return loaded
        } catch {
            // A bundle we cannot open is worse than no bundle: regenerate once rather than
            // leaving the daemon permanently unable to start.
            Log.warn("the stored TLS identity is unusable (\(error)); regenerating it")
            let fresh = try regenerate(at: bundleURL, subjectNames: subjectNames)
            try secrets.set(Data(fresh.utf8), account: passwordAccount)
            return try importIdentity(from: bundleURL, password: fresh, subjectNames: subjectNames)
        }
    }

    // MARK: - Generation

    private static func prepareStateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // createDirectory does not reapply permissions to an existing directory.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw IdentityError.stateDirectoryFailed(error.localizedDescription)
        }
    }

    /// Shells out to the system openssl.
    ///
    /// Generating a self-signed certificate with correct SANs through Security.framework
    /// alone means hand-assembling ASN.1, because macOS exposes no certificate-creation API.
    /// Calling a first-party binary once at first run is the smaller risk. A config file is
    /// used rather than `-addext` because LibreSSL (which ships as /usr/bin/openssl) and
    /// OpenSSL disagree about that flag.
    private static func regenerate(at bundleURL: URL, subjectNames: [String]) throws -> String {
        let openssl = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: openssl) else {
            throw IdentityError.opensslMissing
        }

        let workDirectory = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("tls-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let configURL = workDirectory.appendingPathComponent("openssl.cnf")
        try Self.opensslConfig(subjectNames: subjectNames).write(to: configURL, atomically: true, encoding: .utf8)

        let keyURL = workDirectory.appendingPathComponent("key.pem")
        let certURL = workDirectory.appendingPathComponent("cert.pem")
        let password = Nonce.generate(byteCount: 24).base64URLEncodedString()

        try run(openssl, [
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "398", "-nodes",
            "-keyout", keyURL.path, "-out", certURL.path,
            "-config", configURL.path, "-extensions", "v3_req",
        ])

        // -legacy is required: modern OpenSSL defaults to AES-256 PKCS#12 encryption, which
        // SecPKCS12Import on macOS cannot read. LibreSSL does not accept the flag, so try
        // the modern form and fall back.
        let exportArguments = [
            "pkcs12", "-export", "-inkey", keyURL.path, "-in", certURL.path,
            "-out", bundleURL.path, "-name", certificateLabel, "-passout", "pass:\(password)",
        ]
        do {
            try run(openssl, exportArguments + ["-legacy"])
        } catch {
            try run(openssl, exportArguments)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundleURL.path)
        Log.info("generated a TLS certificate for: \(subjectNames.joined(separator: ", "))")
        return password
    }

    private static func opensslConfig(subjectNames: [String]) -> String {
        var altNames: [String] = []
        var dnsIndex = 1
        var ipIndex = 1
        for name in subjectNames {
            if isIPAddress(name) {
                altNames.append("IP.\(ipIndex) = \(name)")
                ipIndex += 1
            } else {
                altNames.append("DNS.\(dnsIndex) = \(name)")
                dnsIndex += 1
            }
        }
        return """
        [req]
        distinguished_name = dn
        x509_extensions = v3_req
        prompt = no

        [dn]
        CN = AirPoint
        O = AirPoint Local Companion

        [v3_req]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = @alt_names

        [alt_names]
        \(altNames.joined(separator: "\n"))
        """
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, value, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, value, &v6) == 1
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw IdentityError.opensslFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Import

    /// Removes any previously imported AirPoint key/certificate from the keychain.
    ///
    /// `SecPKCS12Import` on macOS materialises the private key in the user's keychain, and
    /// the resulting ACL is bound to the importing binary. After a rebuild — or any change
    /// of code identity — the next `sec_identity_create` blocks on a modal "allow access"
    /// prompt that a background daemon can neither show nor answer, and the TLS handshake
    /// hangs with no error anywhere. Deleting first means every import creates items owned
    /// by the process that will actually use them.
    private static func purgeKeychainItems(label: String) {
        for itemClass in [kSecClassIdentity, kSecClassCertificate, kSecClassKey] {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecAttrLabel as String: label,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                Log.debug("could not purge previous \(itemClass) items (OSStatus \(status))")
            }
        }
    }

    private static func importIdentity(from bundleURL: URL, password: String,
                                       subjectNames: [String]) throws -> Loaded {
        purgeKeychainItems(label: certificateLabel)
        let data = try Data(contentsOf: bundleURL)
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess else { throw IdentityError.importFailed(status) }

        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw IdentityError.noIdentityInBundle
        }
        let identity = identityRef as! SecIdentity

        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        let fingerprint: String
        if let certificate {
            let der = SecCertificateCopyData(certificate) as Data
            fingerprint = Data(SHA256.hash(data: der)).base64URLEncodedString()
        } else {
            fingerprint = ""
            Log.warn("could not read the certificate for fingerprinting; QR pinning will be unavailable")
        }

        return Loaded(identity: identity, certificateFingerprint: fingerprint, subjectNames: subjectNames)
    }

    /// Signs a fixed block with the identity's private key, under a timeout.
    ///
    /// The timeout is the point. If the key's access-control list does not match the running
    /// binary, macOS raises a modal approval prompt; a background daemon can neither show
    /// nor dismiss it, so the call never returns. Waiting a bounded time and treating a
    /// timeout as failure is what converts that hang into a recoverable condition.
    private static func keyIsUsable(_ identity: SecIdentity, timeout: TimeInterval = 3) -> Bool {
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey else { return false }

        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        DispatchQueue.global(qos: .userInitiated).async {
            var error: Unmanaged<CFError>?
            let sample = Data(repeating: 0x41, count: 32) as CFData
            let signature = SecKeyCreateSignature(privateKey,
                                                  .rsaSignatureMessagePKCS1v15SHA256,
                                                  sample, &error)
            succeeded = signature != nil
            error?.release()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            Log.warn("the stored TLS key did not respond within \(Int(timeout))s — it is most likely waiting on a keychain approval prompt this process cannot answer")
            return false
        }
        return succeeded
    }

    /// Wraps the identity for Network.framework.
    static func tlsOptions(for identity: SecIdentity) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        } else {
            Log.error("sec_identity_create failed; TLS handshake will not complete")
        }
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }
}
