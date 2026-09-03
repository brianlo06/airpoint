import Foundation

/// A bounded, thread-safe record of recent log lines, so a UI can answer "what just
/// went wrong" without a terminal.
///
/// `Log` writes to stderr, which a menu-bar app has no window onto. Installing a buffer
/// as `Log.tap` gives a troubleshooting panel something to show while keeping exactly one
/// logging path — every line lands here already subject to the same redaction rules, so
/// the panel can never display something the log would have refused to print.
public final class LogBuffer {

    public struct Entry: Equatable {
        public let date: Date
        public let level: Log.Level
        public let message: String

        public init(date: Date, level: Log.Level, message: String) {
            self.date = date
            self.level = level
            self.message = message
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int
    private let threshold: Log.Level

    /// - Parameters:
    ///   - capacity: entries kept; the oldest are dropped first.
    ///   - keeping: minimum level recorded. Deliberately independent of
    ///     `Log.minimumLevel`, so warnings still reach the panel when stderr is quiet.
    public init(capacity: Int = 50, keeping threshold: Log.Level = .warn) {
        precondition(capacity > 0, "a log buffer that keeps nothing is a bug at the call site")
        self.capacity = capacity
        self.threshold = threshold
    }

    /// Routes `Log` through this buffer. Call once at startup; there is a single tap
    /// slot, so a second install replaces the first rather than fanning out.
    public func installAsTap() {
        Log.tap = { [weak self] level, message in
            self?.record(level: level, message: message)
        }
    }

    public func record(level: Log.Level, message: String, date: Date = Date()) {
        guard level >= threshold else { return }
        lock.lock()
        entries.append(Entry(date: date, level: level, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    /// Newest first, because a troubleshooting panel answers "what just happened".
    public var recent: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed()
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
