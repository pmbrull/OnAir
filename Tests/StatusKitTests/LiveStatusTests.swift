import Foundation
@testable import StatusKit
import Testing

/// The restore rule, which is the whole of ADR-0015 in three cases.
///
/// The failure it exists to prevent is not hypothetical: Google Calendar's Slack app writes "In a
/// meeting" with `status_expiration` set to the end of the event and never returns. Put that
/// status back without its expiry and nothing on either side will ever clear it.
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
}
