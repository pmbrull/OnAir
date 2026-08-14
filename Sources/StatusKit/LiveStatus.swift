import Foundation

/// A status as Slack actually holds it: the pair OnAir writes, plus the expiry it does not.
///
/// The expiry is the whole reason this type exists (ADR-0015). A third-party integration does not
/// come back to tidy up after itself — Google Calendar appears to write "In a meeting" with
/// `status_expiration` set to the end of the event and let Slack clear it, which is inference from
/// Slack's API rather than a capture (GAP-0001). Reading that status as `(emoji, text)` and putting
/// it back without the expiry produces a status nothing will ever clear, because the thing that
/// would have cleared it has already done its half of the job.
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

    /// An expiry this close to falling due is treated as already gone.
    ///
    /// The decision and the write are a network round trip apart, so an expiry two seconds away
    /// would be written back as an expiry in the past — the one input Slack's documented behaviour
    /// says nothing about (GAP-0001). The cost of the horizon is clearing a status up to ten
    /// seconds early, on a status Slack was about to clear anyway.
    public static let expiryHorizon: TimeInterval = 10

    /// Whether Slack has cleared this status, or is about to within the horizon. `0` — never
    /// expires — is not expired however old the status is.
    public func hasExpired(now: Date) -> Bool {
        guard expiresAt > 0 else { return false }
        return TimeInterval(expiresAt) <= now.timeIntervalSince1970 + Self.expiryHorizon
    }

    /// The status as it stands once any expiry has fallen due.
    ///
    /// Read before writing, the *presence* of a status is what the override rule protects
    /// (ADR-0008) — and a status whose expiry has passed is one Slack has already retired, so
    /// treating it as something to protect would leave OnAir writing nothing for a whole call
    /// because of a status nobody can see. Restoring and overwriting must agree about what an
    /// expired status is, or the two halves of ADR-0015 contradict each other.
    public func effectiveStatus(now: Date) -> UserStatus {
        hasExpired(now: now) ? .cleared : status
    }

    /// The restore rule, as a pure function of the stash and the clock (A3).
    public func restoration(now: Date) -> Restoration {
        guard expiresAt > 0 else {
            return .put(status, expiresAt: 0)
        }
        guard !hasExpired(now: now) else {
            return .expired
        }
        return .put(status, expiresAt: expiresAt)
    }
}
