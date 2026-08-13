import Foundation

/// What OnAir wants done to the Slack status right now.
public enum StatusIntent: Sendable, Equatable {
    case doNothing
    /// Write this status. Whether the write is allowed depends on what Slack currently holds,
    /// which only the caller can see — see `StatusEngine.appliedPrevious`.
    case apply(UserStatus)
    /// Put this back, if and only if Slack still holds what OnAir set (ADR-0008). It carries the
    /// expiry it had when OnAir stashed it, because that expiry is the only thing that was ever
    /// going to clear it (ADR-0015).
    case restore(LiveStatus)
}

/// One turn of the loop.
public struct Decision: Sendable, Equatable {
    public let intent: StatusIntent
    /// When to call `advance` again even if nothing else happens — a debounce that has started
    /// but not elapsed. `nil` means nothing is pending and a change notification is the only
    /// reason to come back.
    public let wakeAt: Date?

    public init(intent: StatusIntent, wakeAt: Date?) {
        self.intent = intent
        self.wakeAt = wakeAt
    }
}

/// The whole policy, as a pure state machine.
///
/// It takes device booleans, a `StatusPolicy` and a clock, and returns an intent. It performs no
/// I/O, holds no `Task`, reads no `Date()` of its own and knows nothing about Slack — so every
/// rule worth arguing about (the debounce, the pause, the override, when a restore is owed) is
/// testable in microseconds with no hardware and no network. That is invariant A3, and it is the
/// reason this target depends on nothing.
///
/// The caller drives it:
/// 1. `advance(…)` → an intent, and a `wakeAt` to schedule.
/// 2. Perform the intent against Slack.
/// 3. Report what happened with `recordApplied` / `recordSkipped` / `recordRestored` /
///    `recordFailed`. **Until one of those is called the engine assumes nothing happened**, which
///    is what makes a failed write retry rather than being silently forgotten.
public struct StatusEngine: Sendable, Equatable {
    /// What OnAir believes it has done to the status.
    public enum Applied: Sendable, Equatable {
        /// OnAir has written nothing.
        case idle
        /// OnAir wrote `status`, over a status that read `previous` (often `.cleared`).
        case applied(status: UserStatus, previous: LiveStatus)
        /// OnAir deliberately wrote nothing and will not reconsider until the devices go idle.
        /// Without this the engine would re-read the profile on every single tick of a meeting.
        case skipped(SkipReason)
    }

    public enum SkipReason: String, Sendable, Equatable, Codable {
        /// A status was already set and `overrideExistingStatus` is off.
        case statusAlreadySet
    }

    /// A debounce boundary is compared with this much slack, because a timer fires when the OS
    /// gets round to it and a wake-up that lands 40µs early would otherwise reschedule itself
    /// forever instead of settling.
    private static let tolerance: TimeInterval = 0.001

    public private(set) var settledActive: Bool
    public private(set) var pendingSince: Date?
    public private(set) var applied: Applied

    public init(
        settledActive: Bool = false,
        pendingSince: Date? = nil,
        applied: Applied = .idle
    ) {
        self.settledActive = settledActive
        self.pendingSince = pendingSince
        self.applied = applied
    }

    /// The status OnAir believes it wrote, or `nil` if it wrote nothing.
    public var appliedStatus: UserStatus? {
        if case let .applied(status, _) = applied {
            return status
        }
        return nil
    }

    /// Whether the status Slack currently holds is still the one OnAir wrote.
    ///
    /// The guard on every restore (ADR-0008). Editing your status by hand during a call is a
    /// deliberate act, and putting the old one back over it would undo that edit silently — the
    /// one failure mode here that destroys information rather than merely being wrong.
    ///
    /// The expiry counts as part of "byte-identical": OnAir writes its own status with
    /// `status_expiration: 0` (ADR-0009), so an expiry that has appeared under the same words is
    /// evidence somebody else wrote them.
    public func stillOwns(_ live: LiveStatus) -> Bool {
        guard let ours = appliedStatus else { return false }
        return live == LiveStatus(status: ours, expiresAt: 0)
    }

    /// What was there before OnAir wrote, or `nil` if OnAir has written nothing.
    ///
    /// The caller reads this to tell a **fresh** apply from a **refresh**: on a fresh apply it
    /// must ask Slack what is there and stash it, and on a refresh it must not — the live status
    /// is OnAir's own, and stashing that would make the eventual restore a no-op that strands the
    /// status forever.
    public var appliedPrevious: LiveStatus? {
        if case let .applied(_, previous) = applied {
            return previous
        }
        return nil
    }

    // MARK: - The loop

    public mutating func advance(
        cameraInUse: Bool,
        microphoneInUse: Bool,
        policy: StatusPolicy,
        now: Date
    ) -> Decision {
        // Pause is immediate in both directions. Running it through `offDelay` would mean pressing
        // Pause and watching the status sit there for a minute, which is not what the word means.
        if policy.paused {
            pendingSince = nil
            settledActive = false
            return Decision(intent: releaseIntent(), wakeAt: nil)
        }

        let raw = (policy.watchCamera && cameraInUse)
            || (policy.watchMicrophone && microphoneInUse)

        if raw == settledActive {
            pendingSince = nil
        } else {
            let delay = raw ? policy.onDelay : policy.offDelay
            let since = pendingSince ?? now
            pendingSince = since
            let elapsed = now.timeIntervalSince(since)
            guard elapsed + Self.tolerance >= delay else {
                return Decision(intent: .doNothing, wakeAt: since.addingTimeInterval(delay))
            }
            settledActive = raw
            pendingSince = nil
        }

        return Decision(
            intent: settledActive ? acquireIntent(policy) : releaseIntent(),
            wakeAt: nil
        )
    }

    private func acquireIntent(_ policy: StatusPolicy) -> StatusIntent {
        switch applied {
        case .idle:
            .apply(policy.status)
        case let .applied(status, _):
            // Editing the emoji or the text in Settings mid-call should be visible mid-call.
            status == policy.status ? .doNothing : .apply(policy.status)
        case .skipped:
            // Decided once, for this stretch of activity. Reconsidered when the devices go idle.
            .doNothing
        }
    }

    private mutating func releaseIntent() -> StatusIntent {
        switch applied {
        case let .applied(_, previous):
            // Returned on every tick until the caller reports back, which is the retry.
            return .restore(previous)
        case .skipped:
            // The skip was a decision about *this* stretch of activity. Going idle ends it, so
            // the next meeting asks Slack again instead of inheriting a verdict from the last one.
            applied = .idle
            return .doNothing
        case .idle:
            return .doNothing
        }
    }

    // MARK: - Reporting back

    public mutating func recordApplied(status: UserStatus, previous: LiveStatus) {
        applied = .applied(status: status, previous: previous)
    }

    public mutating func recordSkipped(_ reason: SkipReason) {
        applied = .skipped(reason)
    }

    /// The status was put back — or was found already changed by hand, which counts as released
    /// because OnAir no longer owns it (ADR-0008).
    public mutating func recordRestored() {
        applied = .idle
    }

    /// The write failed. State is left untouched on purpose, so the next `advance` returns the
    /// same intent and the caller retries. A failure that silently advanced the state machine
    /// would strand the status with nothing left to notice.
    public mutating func recordFailed() {}

    /// Called when the token goes away — disconnecting Slack means OnAir owns nothing any more,
    /// and a restore it can no longer perform must not be attempted against the next account.
    public mutating func forgetOwnership() {
        applied = .idle
    }
}
