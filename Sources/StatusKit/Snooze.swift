import Foundation

/// Slack's notification snooze, as OnAir sees it.
///
/// `endsAt` is the unix timestamp Slack reports, kept as the integer it arrives as: ownership is
/// decided by comparing this value exactly (see `SnoozeOwnership`), and converting through `Date`
/// invites sub-second drift into a comparison that must be byte-for-byte.
public struct SnoozeState: Sendable, Equatable {
    public var isSnoozing: Bool
    public var endsAt: Int?

    public init(isSnoozing: Bool, endsAt: Int?) {
        self.isSnoozing = isSnoozing
        self.endsAt = endsAt
    }

    public static let off = SnoozeState(isSnoozing: false, endsAt: nil)
}

/// Whether OnAir may start a snooze over what Slack currently holds.
///
/// The sibling of `OverwriteVerdict` (ADR-0008): a snooze the user set themselves is a deliberate
/// act, and stretching or ending it would destroy information OnAir cannot recreate. Unlike the
/// status there is no override toggle — a user-set snooze always wins, because OnAir snoozing
/// *harder* has no meaning and ending theirs early is pure loss.
public enum SnoozeVerdict: Sendable, Equatable {
    case start
    case leaveAlone
}

public extension StatusPolicy {
    /// How long each snooze slice runs, and how far before its end the caller renews it. Sliced
    /// rather than open-ended on purpose: if OnAir dies mid-call, notifications resume by
    /// themselves within one slice — the opposite trade to the status (ADR-0009), because a stale
    /// status is visible and correctable while missed notifications are silently lost (ADR-0013).
    static let snoozeSliceMinutes = 30
    static let snoozeRenewLeadMinutes = 5

    /// The delay before a slice is renewed, floored at a minute so a mis-set pair of constants
    /// degrades to eager renewal rather than to renewals that always arrive after their slice
    /// lapsed. Computed here rather than at the call site so the floor is testable (A3).
    static var snoozeRenewalDelay: TimeInterval {
        max(60, TimeInterval((snoozeSliceMinutes - snoozeRenewLeadMinutes) * 60))
    }

    func snoozeVerdict(forLive live: SnoozeState) -> SnoozeVerdict {
        live.isSnoozing ? .leaveAlone : .start
    }
}

/// Whether the snooze Slack currently holds is still the one OnAir set.
///
/// Recognition is by the exact endtime Slack returned from the last `setSnooze` — there is no
/// "who set this" field in the API, so the endtime is the only fingerprint available. The user
/// extending or shortening the snooze changes it, and OnAir stands down (ADR-0013).
public struct SnoozeOwnership: Sendable, Equatable {
    /// The endtime of the slice OnAir set, or `nil` when OnAir owns no snooze.
    public private(set) var ourEndtime: Int?

    public init() {}

    public var ownsASnooze: Bool {
        ourEndtime != nil
    }

    public mutating func recordStarted(endtime: Int) {
        ourEndtime = endtime
    }

    public mutating func recordEnded() {
        ourEndtime = nil
    }

    /// `true` when ending the live snooze is ending *ours*. A snooze that is off, or whose
    /// endtime is not the one we set, is not ours to touch.
    public func stillOwns(_ live: SnoozeState) -> Bool {
        guard let ours = ourEndtime, live.isSnoozing else { return false }
        return live.endsAt == ours
    }
}
