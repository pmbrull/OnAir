import Foundation
@testable import StatusKit
import Testing

/// The second half of the engine's rules: what it refuses to reconsider, what it re-applies,
/// what it retries after a failure, and what it still claims to own. An extension rather than
/// a second suite so these cases keep the same fixtures and read as one story with
/// `StatusEngineTests` next door.
extension StatusEngineTests {
    // MARK: - Skipping

    @Test("a skip is not reconsidered for the rest of the call")
    func skipIsSticky() {
        var engine = engineMidCall()
        engine.recordSkipped(.statusAlreadySet)
        let decision = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: policy(), now: at(30)
        )
        #expect(decision.intent == .doNothing, "re-reading the profile every tick is the bug")
    }

    @Test("a skip is reconsidered once the devices go idle")
    func skipEndsWithTheCall() {
        var engine = engineMidCall()
        engine.recordSkipped(.statusAlreadySet)
        let released = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: policy(offDelay: 0), now: at(30)
        )
        #expect(released.intent == .doNothing)

        let nextCall = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: policy(onDelay: 0), now: at(600)
        )
        #expect(nextCall.intent == .apply(onCamera))
    }

    // MARK: - Editing mid-call

    @Test("changing the status mid-call re-applies it")
    func editMidCall() {
        var engine = engineMidCall(previous: standupLive)
        var edited = policy()
        edited.status = UserStatus(emoji: ":red_circle:", text: "On air")
        let decision = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: edited, now: at(10)
        )
        #expect(decision.intent == .apply(edited.status))
    }

    /// The trap a refresh sets: re-reading the live status would stash OnAir's own status as the
    /// thing to restore, and the restore would then be a no-op that strands it (ADR-0008).
    @Test("a refresh must keep the original previous")
    func refreshKeepsPrevious() {
        var engine = engineMidCall(previous: standupLive)
        #expect(engine.appliedPrevious == standupLive)
        let refreshed = UserStatus(emoji: ":red_circle:", text: "On air")
        engine.recordApplied(status: refreshed, previous: engine.appliedPrevious ?? .cleared)
        #expect(engine.appliedPrevious == standupLive)

        let decision = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: policy(offDelay: 0), now: at(20)
        )
        #expect(decision.intent == .restore(standupLive))
    }

    // MARK: - Failure

    @Test("a failed apply is offered again")
    func failedApplyRetries() {
        var engine = StatusEngine()
        let rules = policy(onDelay: 0)
        let first = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: rules, now: at(0)
        )
        #expect(first.intent == .apply(onCamera))
        engine.recordFailed()
        let second = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: rules, now: at(1)
        )
        #expect(second.intent == .apply(onCamera))
    }

    @Test("a failed restore is offered again")
    func failedRestoreRetries() {
        var engine = engineMidCall(previous: standupLive)
        let rules = policy(offDelay: 0)
        let first = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: rules, now: at(10)
        )
        #expect(first.intent == .restore(standupLive))
        engine.recordFailed()
        let second = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: rules, now: at(11)
        )
        #expect(second.intent == .restore(standupLive))
    }

    @Test("restoring stops once it is reported")
    func restoreStops() {
        var engine = engineMidCall(previous: standupLive)
        let rules = policy(offDelay: 0)
        _ = engine.advance(cameraInUse: false, microphoneInUse: false, policy: rules, now: at(10))
        engine.recordRestored()
        let after = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: rules, now: at(11)
        )
        #expect(after.intent == .doNothing)
        #expect(engine.appliedPrevious == nil)
    }

    // MARK: - Ownership

    @Test("forgetting ownership drops the pending restore")
    func forgetOwnership() {
        var engine = engineMidCall(previous: standupLive)
        engine.forgetOwnership()
        let decision = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: policy(offDelay: 0), now: at(10)
        )
        #expect(decision.intent == .doNothing)
    }

    @Test("stillOwns is true only for exactly what was written")
    func ownership() {
        var engine = engineMidCall(previous: standupLive)
        #expect(engine.stillOwns(LiveStatus(status: onCamera)))
        #expect(!engine.stillOwns(
            LiveStatus(status: UserStatus(emoji: ":movie_camera:", text: "On camera "))
        ))
        #expect(!engine.stillOwns(standupLive))
        #expect(!engine.stillOwns(.cleared))
        // OnAir writes `status_expiration: 0`, so the same words carrying an expiry are somebody
        // else's writing, not OnAir's (ADR-0015).
        #expect(!engine.stillOwns(LiveStatus(status: onCamera, expiresAt: 1_700_000_900)))

        engine.recordRestored()
        #expect(!engine.stillOwns(LiveStatus(status: onCamera)), "a released engine owns nothing")
    }
}
