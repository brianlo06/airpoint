import XCTest
@testable import RemoteKit

/// The focus-announcement decision, isolated from the Accessibility API.
///
/// The rule is not "tell the phone when the boolean flips". That version shipped and did
/// not work: the first control focused after connecting is the Terminal the daemon runs in
/// — itself a text area — so it consumed the single announcement, and clicking into a
/// browser search box afterwards changed nothing the phone could see.
final class FocusDecisionTests: XCTestCase {

    private func decide(previous: Bool?, elementChanged: Bool, isText: Bool) -> Bool? {
        FocusDecision.decide(previousValue: previous, elementChanged: elementChanged, isTextInput: isText)
    }

    func testFirstTextFieldIsAnnounced() {
        XCTAssertEqual(decide(previous: nil, elementChanged: true, isText: true), true)
    }

    func testMovingBetweenTwoTextFieldsIsAnnouncedAgain() {
        XCTAssertEqual(decide(previous: true, elementChanged: true, isText: true), true,
                       "clicking from one text field into another must re-offer the keyboard")
    }

    func testStayingInTheSameTextFieldIsSilent() {
        XCTAssertNil(decide(previous: true, elementChanged: false, isText: true),
                     "polling the same field four times a second must not spam the phone")
    }

    func testLosingFocusIsAnnouncedOnce() {
        XCTAssertEqual(decide(previous: true, elementChanged: true, isText: false), false)
        XCTAssertNil(decide(previous: false, elementChanged: true, isText: false),
                     "moving between two non-text controls must stay quiet")
    }

    func testGainingFocusFromNonTextIsAnnounced() {
        XCTAssertEqual(decide(previous: false, elementChanged: true, isText: true), true)
    }

    func testNoFocusAtStartupIsSilent() {
        XCTAssertEqual(decide(previous: nil, elementChanged: false, isText: false), false,
                       "the first poll establishes the baseline, so it reports once")
    }
}
