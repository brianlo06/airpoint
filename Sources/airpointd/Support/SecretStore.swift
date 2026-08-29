import Foundation
import Security

/// Where the daemon keeps things that must not be world-readable: the TLS bundle password
/// and trusted-device public keys.
protocol SecretStore: AnyObject {
    func set(_ data: Data, account: String) throws
    func get(account: String) throws -> Data?
    func delete(account: String) throws
    func deleteAll() throws
    func allAccounts() throws -> [String]
    var describeLocation: String { get }
}

enum SecretStoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case io(String)

    var description: String {
        switch self {
        case .keychain(let status): return "keychain error (OSStatus \(status))"
        case .io(let detail): return "secret store I/O error: \(detail)"
        }
    }
}

/// File-backed store: one 0600 file per account inside a 0700 directory.
///
/// This is the **default** for the CLI daemon, and the reason is worth recording. The
/// macOS Keychain binds an item's access-control list to the exact binary that created it.
/// An unsigned or ad-hoc-signed CLI tool therefore gets a modal "allow access" dialog on
/// every read after every rebuild — and because the daemon starts before any UI exists,
/// that dialog blocks startup with no visible explanation. Filesystem permissions are the
/// honest protection at this stage.
///
/// The threat this does and does not cover: it stops another user account on the machine
/// from reading these files. It does not stop malware already running as this user — but
/// neither does the Keychain once that malware can drive the approval dialog. The signed
/// menu-bar app in Phase 4 gets a stable code identity and switches to `--keychain`.
final class FileSecretStore: SecretStore {

    private let directory: URL
    private let queue = DispatchQueue(label: "com.airpoint.secretstore")

    init(directory: URL) throws {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw SecretStoreError.io(error.localizedDescription)
        }
    }

    var describeLocation: String { "\(directory.path) (file, 0600)" }

    /// Account names become filenames, so they are restricted to a safe alphabet rather
    /// than escaped. A device ID that could contain "../" must never become a path.
    private func url(for account: String) throws -> URL {
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty, safe == account else {
            throw SecretStoreError.io("unsafe account name '\(account)'")
        }
        return directory.appendingPathComponent(safe + ".secret")
    }

    func set(_ data: Data, account: String) throws {
        let target = try url(for: account)
        try queue.sync {
            do {
                try data.write(to: target, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                throw SecretStoreError.io(error.localizedDescription)
            }
        }
    }

    func get(account: String) throws -> Data? {
        let target = try url(for: account)
        return queue.sync { try? Data(contentsOf: target) }
    }

    func delete(account: String) throws {
        let target = try url(for: account)
        queue.sync { try? FileManager.default.removeItem(at: target) }
    }

    func deleteAll() throws {
        try queue.sync {
            let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                         includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.pathExtension == "secret" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func allAccounts() throws -> [String] {
        queue.sync {
            let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                         includingPropertiesForKeys: nil)) ?? []
            return contents.filter { $0.pathExtension == "secret" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }
    }
}

/// Keychain-backed store, for a code-signed host with a stable identity.
/// Enabled with `--keychain`; this is what the Phase 4 menu-bar app will use.
final class KeychainSecretStore: SecretStore {

    private let service: String

    init(service: String) { self.service = service }

    var describeLocation: String { "keychain service '\(service)'" }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func set(_ data: Data, account: String) throws {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        // ThisDeviceOnly: trusting a phone to control *this* Mac must never sync into
        // trusting it to control another one.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    func get(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return result as? Data
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }

    func deleteAll() throws {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status)
        }
    }

    func allAccounts() throws -> [String] {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw SecretStoreError.keychain(status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

enum SecretStoreFactory {
    static func make(config: Config, purpose: String) throws -> SecretStore {
        if config.useKeychain {
            return KeychainSecretStore(service: "com.airpoint.\(purpose)")
        }
        return try FileSecretStore(directory: config.stateDirectory
            .appendingPathComponent("secrets", isDirectory: true)
            .appendingPathComponent(purpose, isDirectory: true))
    }
}
