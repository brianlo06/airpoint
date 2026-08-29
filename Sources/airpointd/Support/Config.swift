import Foundation

/// Runtime configuration. Every value has a safe default, can be overridden by an
/// environment variable, and can be overridden again by a command-line flag.
///
/// There are no hard-coded addresses anywhere in the daemon: the bind host is derived from
/// the live network interfaces at startup, not baked in.
public struct Config {
    public var port: UInt16 = 8443
    /// Interface to bind. `nil` means "all private interfaces"; a public address is refused
    /// unless `allowPublicBind` is explicitly set.
    public var bindHost: String?
    public var allowPublicBind = false
    public var logLevel: Log.Level = .info
    /// Directory for the TLS identity and the trusted-device store.
    public var stateDirectory: URL
    /// Skip the interactive approval prompt. Intended for automated tests only; it is
    /// refused unless the daemon is also bound to loopback.
    public var autoApprovePairing = false
    /// Serve the controller and accept connections, but never post real input events.
    public var dryRun = false
    /// Move the cursor in a square and exit. Verifies the Accessibility permission end to end.
    public var selfTest = false
    /// Store secrets in the macOS Keychain instead of permission-restricted files.
    /// Only appropriate for a code-signed host — see SecretStore.swift for why.
    public var useKeychain = false

    public static func defaultStateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AirPoint", isDirectory: true)
    }

    public init() {
        stateDirectory = Config.defaultStateDirectory()
    }

    public enum ParseError: Error, CustomStringConvertible {
        case unknownFlag(String)
        case missingValue(String)
        case invalidValue(flag: String, value: String)
        case unsafeCombination(String)

        public var description: String {
            switch self {
            case .unknownFlag(let f): return "unknown flag '\(f)'"
            case .missingValue(let f): return "'\(f)' requires a value"
            case .invalidValue(let f, let v): return "invalid value '\(v)' for '\(f)'"
            case .unsafeCombination(let m): return m
            }
        }
    }

    public static func load(arguments: [String] = Array(CommandLine.arguments.dropFirst()),
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        var config = Config()

        // Environment first, so flags win.
        if let raw = environment["AIRPOINT_PORT"] {
            guard let port = UInt16(raw) else { throw ParseError.invalidValue(flag: "AIRPOINT_PORT", value: raw) }
            config.port = port
        }
        if let host = environment["AIRPOINT_BIND_HOST"] { config.bindHost = host }
        if let dir = environment["AIRPOINT_STATE_DIR"] {
            config.stateDirectory = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        if let level = environment["AIRPOINT_LOG_LEVEL"] { config.logLevel = parseLevel(level) ?? .info }

        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else { throw ParseError.missingValue(flag) }
                index += 1
                return arguments[index]
            }
            switch flag {
            case "--port":
                let raw = try value()
                guard let port = UInt16(raw), port >= 1024 else {
                    throw ParseError.invalidValue(flag: flag, value: raw)
                }
                config.port = port
            case "--bind":
                config.bindHost = try value()
            case "--state-dir":
                config.stateDirectory = URL(fileURLWithPath: (try value() as NSString).expandingTildeInPath)
            case "--log-level":
                let raw = try value()
                guard let level = parseLevel(raw) else { throw ParseError.invalidValue(flag: flag, value: raw) }
                config.logLevel = level
            case "--dry-run":
                config.dryRun = true
            case "--selftest":
                config.selfTest = true
            case "--keychain":
                config.useKeychain = true
            case "--auto-approve":
                config.autoApprovePairing = true
            case "--i-know-what-im-doing":
                config.allowPublicBind = true
            case "--help", "-h":
                print(Config.usage)
                exit(0)
            default:
                throw ParseError.unknownFlag(flag)
            }
            index += 1
        }

        // Refuse the two combinations that would turn a convenience into a hole.
        if config.allowPublicBind {
            Log.warn("public bind explicitly enabled — this exposes input control beyond your LAN")
        }
        if config.autoApprovePairing {
            let host = config.bindHost ?? ""
            guard host == "127.0.0.1" || host == "::1" || host == "localhost" else {
                throw ParseError.unsafeCombination(
                    "--auto-approve requires --bind 127.0.0.1; approving pairings automatically on a LAN interface would let any device on the network take over the machine")
            }
        }
        return config
    }

    private static func parseLevel(_ raw: String) -> Log.Level? {
        switch raw.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warn", "warning": return .warn
        case "error": return .error
        default: return nil
        }
    }

    public static let usage = """
    airpointd — AirPoint desktop companion

    USAGE:
      airpointd [options]

    OPTIONS:
      --port <n>            TLS port to listen on (default 8443, env AIRPOINT_PORT)
      --bind <host>         Interface to bind (default: all private interfaces)
      --state-dir <path>    TLS identity + trusted devices (env AIRPOINT_STATE_DIR)
      --log-level <level>   debug | info | warn | error (env AIRPOINT_LOG_LEVEL)
      --dry-run             Accept connections but never post real input events
      --keychain            Store secrets in the Keychain (code-signed hosts only)
      --auto-approve        Skip the approval prompt; requires --bind 127.0.0.1
      --i-know-what-im-doing  Permit binding a non-private address
      --selftest            Move the cursor in a square and exit (checks permissions)
      -h, --help            This help

    Requires the Accessibility permission (System Settings > Privacy & Security >
    Accessibility) to post input events. Run --selftest to verify it.
    """
}
