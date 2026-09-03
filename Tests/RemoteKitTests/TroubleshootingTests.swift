import XCTest
@testable import RemoteKit
import AirPointCore

/// The logic behind the menu-bar app's troubleshooting panel: the recent-issues buffer
/// and the firewall-state parser. The panel itself needs eyes; these do not.
final class LogBufferTests: XCTestCase {

    func testKeepsOnlyWarningsAndAbove() {
        let buffer = LogBuffer(capacity: 10, keeping: .warn)
        buffer.record(level: .debug, message: "chatty")
        buffer.record(level: .info, message: "routine")
        buffer.record(level: .warn, message: "concerning")
        buffer.record(level: .error, message: "broken")
        XCTAssertEqual(buffer.recent.map(\.message), ["broken", "concerning"])
    }

    func testNewestFirst() {
        let buffer = LogBuffer(capacity: 10, keeping: .warn)
        buffer.record(level: .warn, message: "first")
        buffer.record(level: .warn, message: "second")
        XCTAssertEqual(buffer.recent.map(\.message), ["second", "first"],
                       "a troubleshooting panel answers 'what just happened'")
    }

    func testCapacityDropsTheOldest() {
        let buffer = LogBuffer(capacity: 3, keeping: .warn)
        for i in 1...5 { buffer.record(level: .warn, message: "line \(i)") }
        XCTAssertEqual(buffer.recent.map(\.message), ["line 5", "line 4", "line 3"])
    }

    func testThresholdIsIndependentOfLogMinimumLevel() {
        let previous = Log.minimumLevel
        defer { Log.minimumLevel = previous }
        Log.minimumLevel = .error

        let buffer = LogBuffer(capacity: 10, keeping: .warn)
        buffer.installAsTap()
        defer { Log.tap = nil }

        Log.warn("quiet on stderr, loud in the panel")
        XCTAssertEqual(buffer.recent.count, 1,
                       "warnings must reach the panel even when stderr logging is turned down")
    }

    func testTapReceivesRedactedFormsOnly() {
        let buffer = LogBuffer(capacity: 10, keeping: .warn)
        buffer.installAsTap()
        defer { Log.tap = nil }

        // The tap is a second reader of the one logging path, so what call sites redact
        // stays redacted. This asserts the helpers, since the tap sees finished strings.
        Log.warn("typed \(Log.redacted("secret text"))")
        let message = buffer.recent.first?.message ?? ""
        XCTAssertFalse(message.contains("secret text"))
        XCTAssertTrue(message.contains("11 chars redacted"))
    }

    func testClear() {
        let buffer = LogBuffer(capacity: 10, keeping: .warn)
        buffer.record(level: .error, message: "stale")
        buffer.clear()
        XCTAssertTrue(buffer.recent.isEmpty)
    }
}

final class FirewallStateTests: XCTestCase {

    func testParsesTheThreeRealStates() {
        XCTAssertEqual(FirewallState.parse("Firewall is disabled. (State = 0)"), .off)
        XCTAssertEqual(FirewallState.parse("Firewall is enabled. (State = 1)"), .on)
        XCTAssertEqual(FirewallState.parse(
            "Firewall is set to block all non-essential incoming connections. (State = 2)"),
            .blockingAll)
    }

    func testSurvivesRewordedSentences() {
        // The numeric state is the contract; the prose around it is not.
        XCTAssertEqual(FirewallState.parse("Le pare-feu est activé. (State = 1)"), .on)
    }

    func testUnparseableOutputIsUnknownNotACrash() {
        XCTAssertEqual(FirewallState.parse(""), .unknown)
        XCTAssertEqual(FirewallState.parse("Firewall is enabled."), .unknown)
        XCTAssertEqual(FirewallState.parse("State = "), .unknown)
        XCTAssertEqual(FirewallState.parse("State = x"), .unknown)
        XCTAssertEqual(FirewallState.parse("State = 7"), .unknown)
    }
}
