import Foundation

/// When to tell the client that the host's focused control accepts typed text.
///
/// Lives here rather than beside the Accessibility code so it can be tested without a
/// window server, and so the native iOS client shares the same rule.
///
/// The rule is deliberately not "announce when the boolean flips". That version shipped and
/// did not work: the first control focused after connecting is, in practice, the Terminal
/// the daemon runs in — itself a text area — so it consumed the single announcement, and
/// clicking into a browser search box afterwards changed nothing the phone could observe.
public enum FocusDecision {

    /// Returns the value to announce, or `nil` to stay quiet.
    ///
    /// - Parameters:
    ///   - previousValue: what was last announced, or nil before the first poll.
    ///   - elementChanged: whether focus moved to a different control.
    ///   - isTextInput: whether the newly focused control accepts typed text.
    public static func decide(previousValue: Bool?, elementChanged: Bool, isTextInput: Bool) -> Bool? {
        if isTextInput {
            // A different text field is news even when the previous one also accepted text.
            return (elementChanged || previousValue != true) ? true : nil
        }
        // Losing text focus is worth saying once; moving between non-text controls is not.
        return previousValue == false ? nil : false
    }
}
