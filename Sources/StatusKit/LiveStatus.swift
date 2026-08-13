import Foundation

/// A status as Slack actually holds it: the pair OnAir writes, plus the expiry it does not.
///
/// The expiry is the whole reason this type exists (ADR-0015). Third-party integrations do not
/// come back to tidy up after themselves — Google Calendar writes "In a meeting" with
/// `status_expiration` set to the end of the event and lets Slack clear it. Reading that status as
/// `(emoji, text)` and putting it back without the expiry produces a status nothing will ever
/// clear, because the thing that would have cleared it has already done its half of the job.
public struct LiveStatus: Sendable, Equatable {
    public var status: UserStatus
    /// Slack's `status_expiration`: the Unix time at which Slack itself clears this status.
    /// `0` means never, which is what a status typed by hand carries.
    public var expiresAt: Int

    public init(status: UserStatus, expiresAt: Int = 0) {
        self.status = status
        self.expiresAt = expiresAt
    }

    public static let cleared = LiveStatus(status: .cleared, expiresAt: 0)

    /// What to write to put this status back.
    public enum Restoration: Sendable, Equatable {
        /// Write this, with this expiry. `.cleared` here is the ordinary "you had no status
        /// before" case, not an expiry.
        case put(UserStatus, expiresAt: Int)
        /// The expiry passed while OnAir held the status. Slack would have cleared it during the
        /// call, so putting the words back would resurrect a status the user already stopped
        /// having — clear instead.
        case expired
    }

    /// The restore rule, as a pure function of the stash and the clock (A3).
    public func restoration(now: Date) -> Restoration {
        guard expiresAt > 0 else {
            return .put(status, expiresAt: 0)
        }
        guard TimeInterval(expiresAt) > now.timeIntervalSince1970 else {
            return .expired
        }
        return .put(status, expiresAt: expiresAt)
    }
}
