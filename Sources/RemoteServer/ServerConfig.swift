import Foundation
import RemoteKit

/// Everything the server needs, with nothing application-specific in it.
///
/// Split out of the daemon's CLI configuration so a host application can construct one
/// directly without inheriting AirPoint's flags, defaults or opinions.
public struct ServerConfig {

    public var port: UInt16
    /// Interface to bind. `nil` means every private interface.
    public var bindHost: String?
    /// Binding a non-private address is refused unless this is set. See `Server.start()`.
    public var allowPublicBind: Bool
    /// Where the TLS identity and trusted devices live.
    public var stateDirectory: URL
    /// Keychain rather than permission-restricted files. Only for code-signed hosts.
    public var useKeychain: Bool

    /// Bonjour advertisement.
    public var serviceName: String
    public var serviceType: String

    /// Reported to clients, and compared against what they report, so a stale page held in
    /// a backgrounded browser tab is detected instead of silently misbehaving.
    public var serverVersion: String
    public var expectedClientVersion: String

    /// How many devices may hold an authenticated session at once.
    ///
    /// AirPoint uses 1: two phones fighting over one cursor is not a feature. A game uses
    /// one per player. This is the single number that separates the two products.
    public var maxConcurrentSessions: Int

    /// The controller assets to serve.
    public var staticContent: StaticContent

    public init(port: UInt16 = 8443,
                bindHost: String? = nil,
                allowPublicBind: Bool = false,
                stateDirectory: URL,
                useKeychain: Bool = false,
                serviceName: String,
                serviceType: String,
                serverVersion: String,
                expectedClientVersion: String,
                maxConcurrentSessions: Int = 1,
                staticContent: StaticContent) {
        self.port = port
        self.bindHost = bindHost
        self.allowPublicBind = allowPublicBind
        self.stateDirectory = stateDirectory
        self.useKeychain = useKeychain
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.serverVersion = serverVersion
        self.expectedClientVersion = expectedClientVersion
        self.maxConcurrentSessions = maxConcurrentSessions
        self.staticContent = staticContent
    }
}

/// The files a host serves to its controller, resolved from a fixed allowlist.
///
/// An allowlist rather than a directory join, so there is no path arithmetic to get wrong
/// and therefore no traversal to defend against.
public struct StaticContent {
    public let bundle: Bundle
    public let subdirectory: String?
    /// Request path to filename. Paths absent from this map return 404.
    public let allowlist: [String: String]

    public init(bundle: Bundle, subdirectory: String?, allowlist: [String: String]) {
        self.bundle = bundle
        self.subdirectory = subdirectory
        self.allowlist = allowlist
    }

    /// The conventional set for a controller built as plain ES modules.
    public static func webController(bundle: Bundle,
                                     subdirectory: String? = "web",
                                     extra: [String: String] = [:]) -> StaticContent {
        var allowlist: [String: String] = [
            "/": "index.html",
            "/index.html": "index.html",
            "/app.css": "app.css",
            "/app.js": "app.js",
            "/motion.js": "motion.js",
            "/typing.js": "typing.js",
            "/manifest.webmanifest": "manifest.webmanifest",
        ]
        allowlist.merge(extra) { _, new in new }
        return StaticContent(bundle: bundle, subdirectory: subdirectory, allowlist: allowlist)
    }
}
