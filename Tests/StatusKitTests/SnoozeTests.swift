import Foundation
@testable import StatusKit
import Testing

/// The two rules that keep the snooze polite (ADR-0013), pure and tested for the same reason the
/// status rules are: the app target cannot assert on anything (A3).
@Suite("Snooze rules")
struct SnoozeTests {
    // MARK: - The verdict

    /// Unlike the status there is no override toggle: a user-set snooze always wins, because
    /// snoozing harder has no meaning and ending theirs early is pure loss.
    @Test("an active snooze is never touched")
    func activeSnoozeWins() {
        let live = SnoozeState(isSnoozing: true, endsAt: 1_450_373_897)
        #expect(StatusPolicy.standard.snoozeVerdict(forLive: live) == .leaveAlone)
        var overriding = StatusPolicy.standard
        overriding.overrideExistingStatus = true
        #expect(
            overriding.snoozeVerdict(forLive: live) == .leaveAlone,
            "the status override toggle must not leak into the snooze rule"
        )
    }

    @Test("no snooze means OnAir may start one")
    func offMeansStart() {
        #expect(StatusPolicy.standard.snoozeVerdict(forLive: .off) == .start)
    }

    // MARK: - Ownership

    @Test("ownership is the exact endtime Slack returned, nothing looser")
    func ownershipIsExact() {
        var ownership = SnoozeOwnership()
        #expect(!ownership.ownsASnooze)

        ownership.recordStarted(endtime: 1_450_373_897)
        #expect(ownership.ownsASnooze)
        #expect(ownership.stillOwns(SnoozeState(isSnoozing: true, endsAt: 1_450_373_897)))
        // The user extending or shortening the snooze changes the endtime — theirs now.
        #expect(!ownership.stillOwns(SnoozeState(isSnoozing: true, endsAt: 1_450_373_898)))
        // Ended by hand (or lapsed): nothing left to end.
        #expect(!ownership.stillOwns(.off))
    }

    @Test("a renewal replaces the fingerprint; ending clears it")
    func renewalAndEnd() {
        var ownership = SnoozeOwnership()
        ownership.recordStarted(endtime: 100)
        ownership.recordStarted(endtime: 200)
        #expect(!ownership.stillOwns(SnoozeState(isSnoozing: true, endsAt: 100)))
        #expect(ownership.stillOwns(SnoozeState(isSnoozing: true, endsAt: 200)))

        ownership.recordEnded()
        #expect(!ownership.ownsASnooze)
        #expect(!ownership.stillOwns(SnoozeState(isSnoozing: true, endsAt: 200)))
    }

    // MARK: - The policy field

    @Test("pauseNotifications ships off")
    func shippedDefault() {
        #expect(!StatusPolicy.standard.pauseNotifications)
    }

    /// A policy written before this feature existed must decode with the new key at its default,
    /// not reset the user's other settings.
    @Test("a pre-ADR-0013 policy decodes with the snooze off")
    func forwardCompatibleDecode() throws {
        let older = Data("""
        {"status":{"emoji":":red_circle:","text":"On air"},"overrideExistingStatus":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(StatusPolicy.self, from: older)
        #expect(decoded.overrideExistingStatus)
        #expect(!decoded.pauseNotifications)
    }

    /// The slice geometry the self-healing property depends on: a renewal must come due while
    /// the slice it renews is still running.
    @Test("the renewal lead fits inside the slice")
    func sliceGeometry() {
        #expect(StatusPolicy.snoozeRenewLeadMinutes > 0)
        #expect(StatusPolicy.snoozeRenewLeadMinutes < StatusPolicy.snoozeSliceMinutes)
    }
}
