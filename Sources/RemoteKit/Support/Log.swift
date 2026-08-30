import Foundation

/// Levelled logger with a hard rule: it never prints a secret.
///
/// Typed text, pairing codes, proofs, session tokens and key names are all deliberately
/// absent from every log site. A remote-control tool that logs its own input stream is a
/// keylogger with extra steps, so the redaction lives here rather than in the discipline
/// of whoever writes the next log line.
public enum Log {
    public enum Level: Int, Comparable {
        case debug = 0, info = 1, warn = 2, error = 3
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info:  return "INFO "
            case .warn:  return "WARN "
            case .error: return "ERROR"
            }
        }
    }

    nonisolated(unsafe) public static var minimumLevel: Level = .info

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    public static func info(_ message: @autoclosure () -> String)  { emit(.info, message()) }
    public static func warn(_ message: @autoclosure () -> String)  { emit(.warn, message()) }
    public static func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

    private static func emit(_ level: Level, _ message: String) {
        guard level >= minimumLevel else { return }
        let line = "\(formatter.string(from: Date())) \(level.label) \(message)\n"
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }

    /// Shortens an opaque identifier for logs. Enough to correlate two lines, not enough
    /// to reconstruct the value.
    public static func short(_ identifier: String) -> String {
        identifier.count <= 8 ? identifier : String(identifier.prefix(8)) + "…"
    }

    /// Redacts a length rather than a value, for anything user-typed.
    public static func redacted(_ text: String) -> String {
        "<\(text.count) chars redacted>"
    }
}
