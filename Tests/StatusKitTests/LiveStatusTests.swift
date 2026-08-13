import Foundation
@testable import StatusKit
import Testing

/// The restore rule, which is the whole of ADR-0015 in three cases.
///
/// The failure it exists to prevent was reported from a real menu: a "In a meeting • Google
/// Calendar" status that never went away. The mechanism OnAir believes is behind it — the
/// integration sets `status_expiration` to the event's end and never returns — is inference from
/// Slack's API rather than something captured, and GAP-0001 says so. The rule below holds either
/// way: put a status back without the expiry it arrived with and nothing on either side will
/// clear it.
@Suite("Live status")
struct LiveStatusTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let meeting = UserStatus(emoji: ":spiral_calendar_pad:", text: "In a meeting")

    @Test("a status with no expiry goes back exactly as it was")
    func neverExpires() {
        let stash = LiveStatus(status: meeting, expiresAt: 0)
        #expect(stash.restoration(now: now) == .put(meeting, expiresAt: 0))
    }

    @Test("having had no status still restores as a clear, not as an expiry")
    func clearedGoesBackCleared() {
        #expect(LiveStatus.cleared.restoration(now: now) == .put(.cleared, expiresAt: 0))
    }

    @Test("an expiry still ahead rides back with the status")
    func futureExpiryIsCarried() {
        let stash = LiveStatus(status: meeting, expiresAt: 1_700_003_600)
        #expect(stash.restoration(now: now) == .put(meeting, expiresAt: 1_700_003_600))
    }

    /// The case that reads as counter-intuitive and is not: the user's meeting ended while they
    /// were still on camera. Slack would have cleared that status during the call, so putting the
    /// words back would give them a status they had already stopped having.
    @Test("an expiry that passed during the call clears instead of restoring")
    func passedExpiryClears() {
        let stash = LiveStatus(status: meeting, expiresAt: 1_699_999_000)
        #expect(stash.restoration(now: now) == .expired)
    }

    /// The boundary is decided one way on purpose: an expiry at exactly *now* has arrived, and
    /// writing it back would ask Slack to schedule a clear in the past.
    @Test("an expiry landing exactly now counts as passed")
    func expiryOnTheBoundary() {
        let stash = LiveStatus(status: meeting, expiresAt: 1_700_000_000)
        #expect(stash.restoration(now: now) == .expired)
    }

    /// The write is a network round trip after the decision, so an expiry a few seconds out would
    /// reach Slack already in the past — the one input its documented behaviour is silent on.
    @Test("an expiry inside the horizon is treated as already gone")
    func expiryInsideTheHorizon() {
        let justInside = LiveStatus(status: meeting, expiresAt: 1_700_000_009)
        let justOutside = LiveStatus(status: meeting, expiresAt: 1_700_000_011)
        #expect(justInside.restoration(now: now) == .expired)
        #expect(justOutside.restoration(now: now) == .put(meeting, expiresAt: 1_700_000_011))
    }

    /// The two halves of ADR-0015 have to agree about what an expired status is. If the restore
    /// says "gone" and the override rule says "already set", OnAir writes nothing for a whole call
    /// because of a status Slack has already retired.
    @Test("an expired status is writable, the way a cleared one is")
    func expiredStatusIsWritable() {
        var rules = StatusPolicy.standard
        rules.overrideExistingStatus = false
        let expired = LiveStatus(status: meeting, expiresAt: 1_699_999_000)
        let alive = LiveStatus(status: meeting, expiresAt: 1_700_003_600)

        #expect(expired.effectiveStatus(now: now) == .cleared)
        #expect(rules.verdict(forLive: expired.effectiveStatus(now: now)) == .write)

        #expect(alive.effectiveStatus(now: now) == meeting)
        #expect(
            rules.verdict(forLive: alive.effectiveStatus(now: now))
                == .leaveAlone(.statusAlreadySet)
        )
    }

    /// A status with no expiry is never expired, however old it is.
    @Test("never-expires is not expired")
    func neverExpiresIsNotExpired() {
        let stash = LiveStatus(status: meeting, expiresAt: 0)
        #expect(!stash.hasExpired(now: now.addingTimeInterval(86400 * 365)))
        #expect(stash.effectiveStatus(now: now) == meeting)
    }
}
