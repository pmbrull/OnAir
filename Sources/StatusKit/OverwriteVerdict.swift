import Foundation

/// Whether OnAir may write over what Slack currently holds.
public enum OverwriteVerdict: Sendable, Equatable {
    case write
    case leaveAlone(StatusEngine.SkipReason)
}

public extension StatusPolicy {
    /// The override rule, as a function of the policy and what Slack actually holds.
    ///
    /// It lives here rather than in the caller for one reason: it is the rule most likely to be
    /// got wrong, and the app target has no tests. Anything that decides belongs in this target
    /// (invariant A3); the caller's job is to fetch `live` and to obey.
    func verdict(forLive live: UserStatus) -> OverwriteVerdict {
        if live.isCleared || overrideExistingStatus {
            return .write
        }
        return .leaveAlone(.statusAlreadySet)
    }
}
