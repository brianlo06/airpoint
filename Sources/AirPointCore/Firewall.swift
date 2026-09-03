import Foundation

/// The macOS application firewall, as far as a troubleshooting panel needs to know.
///
/// A firewall blocking incoming connections is the most common reason "the phone cannot
/// reach the Mac" on a machine that is otherwise configured correctly, and nothing in the
/// connect path can see it — the listener binds successfully and simply never hears from
/// anyone. So the state is surfaced where the user is already looking.
public enum FirewallState: Equatable {
    case off
    case on
    case blockingAll
    case unknown

    /// Parses `socketfilterfw --getglobalstate` output, e.g.
    /// `Firewall is disabled. (State = 0)`. The numeric state is the contract; the
    /// sentence around it changes wording between macOS releases and is not.
    public static func parse(_ output: String) -> FirewallState {
        guard let range = output.range(of: "State = "),
              let digit = output[range.upperBound...].first,
              let value = digit.wholeNumberValue else { return .unknown }
        switch value {
        case 0: return .off
        case 1: return .on
        case 2: return .blockingAll
        default: return .unknown
        }
    }

    /// Asks the system tool, which is readable without privileges. Any failure — the
    /// binary moving, a sandbox denial, unparseable output — is `.unknown`, because a
    /// troubleshooting panel must never itself become a thing to troubleshoot.
    public static func probe() -> FirewallState {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        process.arguments = ["--getglobalstate"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .unknown
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }
}
