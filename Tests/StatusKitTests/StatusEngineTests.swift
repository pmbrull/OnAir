import Foundation
@testable import StatusKit
import Testing

/// The engine is where every rule worth arguing about lives, and it is pure — so these tests state
/// a situation as a literal and a clock as an offset, with no hardware and no network anywhere.
///
/// Swift Testing rather than XCTest throughout this package: XCTest ships with Xcode, and a
/// machine with only the Command Line Tools cannot build a test target that imports it
/// (`docs/dev-loop.md`).
@Suite("Status engine")
struct StatusEngineTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let onCamera = UserStatus(emoji: ":movie_camera:", text: "On camera")
    private let standup = UserStatus(emoji: ":coffee:", text: "Standup")
    /// What Slack holds before OnAir writes: the status, plus the expiry only Slack knows about.
    ///
    /// Deliberately carries a non-zero expiry. With `0` here, a regression that re-stashed
    /// `LiveStatus(status: previous.status)` on a refresh — dropping the clock and reintroducing
    /// the ADR-0015 bug on that path alone — would satisfy every assertion in this suite.
    private let standupLive = LiveStatus(
        status: UserStatus(emoji: ":coffee:", text: "Standup"),
        expiresAt: 1_700_009_999
    )

    private func policy(
        onDelay: TimeInterval = 3,
        offDelay: TimeInterval = 60,
        watchCamera: Bool = true,
        watchMicrophone: Bool = false,
        overrideExisting: Bool = false,
        paused: Bool = false
    ) -> StatusPolicy {
        StatusPolicy(
            status: onCamera,
            watchCamera: watchCamera,
            watchMicrophone: watchMicrophone,
            overrideExistingStatus: overrideExisting,
            onDelay: onDelay,
            offDelay: offDelay,
            paused: paused
        )
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Drives the engine to the state it is in during a call OnAir already owns.
    private func engineMidCall(previous: LiveStatus = .cleared) -> StatusEngine {
        var engine = StatusEngine()
        let rules = policy()
        _ = engine.advance(cameraInUse: true, microphoneInUse: false, policy: rules, now: at(0))
        let settled = engine.advance(
            cameraInUse: true,
            microphoneInUse: false,
            policy: rules,
            now: at(3)
        )
        #expect(settled.intent == .apply(onCamera), "setup did not reach the apply")
        engine.recordApplied(status: onCamera, previous: previous)
        return engine
    }

    // MARK: - Doing nothing

    @Test("idle does nothing and schedules nothing")
    func idle() {
        var engine = StatusEngine()
        let decision = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: policy(), now: at(0)
        )
        #expect(decision.intent == .doNothing)
        #expect(decision.wakeAt == nil)
    }

    // MARK: - Turning on

    @Test("camera on waits for the on-delay and says when to come back")
    func onDelayIsAnnounced() {
        var engine = StatusEngine()
        let decision = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: policy(onDelay: 3), now: at(0)
        )
        #expect(decision.intent == .doNothing)
        #expect(decision.wakeAt == at(3))
    }

    @Test("camera on applies once the on-delay has elapsed")
    func appliesAfterOnDelay() {
        var engine = StatusEngine()
        let rules = policy(onDelay: 3)
        _ = engine.advance(cameraInUse: true, microphoneInUse: false, policy: rules, now: at(0))
        let decision = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: rules, now: at(3)
        )
        #expect(decision.intent == .apply(onCamera))
        #expect(decision.wakeAt == nil)
    }

    /// The reason `onDelay` exists: apps enumerate cameras at launch, and a blip must not reach
    /// anybody's sidebar.
    @Test("a blip shorter than the on-delay never applies")
    func blipIsSwallowed() {
        var engine = StatusEngine()
        let rules = policy(onDelay: 3)
        _ = engine.advance(cameraInUse: true, microphoneInUse: false, policy: rules, now: at(0))
        let off = engine.advance(
            cameraInUse: false,
            microphoneInUse: false,
            policy: rules,
            now: at(1)
        )
        #expect(off.intent == .doNothing)
        let later = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: rules, now: at(120)
        )
        #expect(later.intent == .doNothing)
    }

    @Test("the debounce restarts after a blip")
    func debounceRestarts() {
        var engine = StatusEngine()
        let rules = policy(onDelay: 3)
        _ = engine.advance(cameraInUse: true, microphoneInUse: false, policy: rules, now: at(0))
        _ = engine.advance(cameraInUse: false, microphoneInUse: false, policy: rules, now: at(1))
        let restarted = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: rules, now: at(2)
        )
        #expect(restarted.wakeAt == at(5), "the second attempt must wait its own full delay")
    }

    @Test("a zero on-delay applies immediately")
    func zeroDelay() {
        var engine = StatusEngine()
        let decision = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: policy(onDelay: 0), now: at(0)
        )
        #expect(decision.intent == .apply(onCamera))
    }

    // MARK: - The two sources

    @Test("the microphone alone is enough when it is watched")
    func microphoneAlone() {
        var engine = StatusEngine()
        let rules = policy(onDelay: 0, watchMicrophone: true)
        let decision = engine.advance(
            cameraInUse: false, microphoneInUse: true, policy: rules, now: at(0)
        )
        #expect(decision.intent == .apply(onCamera))
    }

    /// The shipped default, and the reason for it (ADR-0011): a mixer holding the microphone open
    /// must not pin the status on.
    @Test("an unwatched microphone is ignored even while running")
    func unwatchedMicrophone() {
        var engine = StatusEngine()
        let rules = policy(onDelay: 0, watchMicrophone: false)
        let decision = engine.advance(
            cameraInUse: false, microphoneInUse: true, policy: rules, now: at(0)
        )
        #expect(decision.intent == .doNothing)
        #expect(decision.wakeAt == nil)
    }

    @Test("un-watching the camera mid-call releases the status")
    func unwatchingReleases() {
        var engine = engineMidCall(previous: standupLive)
        let rules = policy(offDelay: 0, watchCamera: false)
        let decision = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: rules, now: at(10)
        )
        #expect(decision.intent == .restore(standupLive))
    }

    // MARK: - Turning off

    @Test("camera off waits for the off-delay before restoring")
    func offDelayIsRespected() {
        var engine = engineMidCall(previous: standupLive)
        let rules = policy(offDelay: 60)
        let pending = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: rules, now: at(10)
        )
        #expect(pending.intent == .doNothing)
        #expect(pending.wakeAt == at(70))

        let restored = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: rules, now: at(70)
        )
        #expect(restored.intent == .restore(standupLive))
    }

    /// The reason `offDelay` is long: back-to-back meetings should not write to Slack twice in
    /// the gap between them.
    @Test("a gap shorter than the off-delay neither restores nor re-applies")
    func backToBackMeetings() {
        var engine = engineMidCall(previous: standupLive)
        let rules = policy(offDelay: 60)
        _ = engine.advance(cameraInUse: false, microphoneInUse: false, policy: rules, now: at(10))
        let backOn = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: rules, now: at(40)
        )
        #expect(backOn.intent == .doNothing)
        #expect(backOn.wakeAt == nil, "the pending restore must be cancelled, not merely postponed")
    }

    @Test("restoring an empty previous clears rather than writes")
    func restoringEmpty() {
        var engine = engineMidCall(previous: .cleared)
        let decision = engine.advance(
            cameraInUse: false, microphoneInUse: false, policy: policy(offDelay: 0), now: at(10)
        )
        #expect(decision.intent == .restore(.cleared))
    }

    // MARK: - Pause

    @Test("pause restores immediately rather than waiting out the off-delay")
    func pauseIsImmediate() {
        var engine = engineMidCall(previous: standupLive)
        let decision = engine.advance(
            cameraInUse: true,
            microphoneInUse: false,
            policy: policy(offDelay: 600, paused: true),
            now: at(10)
        )
        #expect(decision.intent == .restore(standupLive))
        #expect(decision.wakeAt == nil)
    }

    @Test("pause with nothing applied does nothing")
    func pauseWithNothingApplied() {
        var engine = StatusEngine()
        let decision = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: policy(paused: true), now: at(0)
        )
        #expect(decision.intent == .doNothing)
    }

    @Test("un-pausing while the camera is still on starts the on-delay again")
    func unpausing() {
        var engine = engineMidCall(previous: standupLive)
        _ = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: policy(paused: true), now: at(10)
        )
        engine.recordRestored()
        let resumed = engine.advance(
            cameraInUse: true, microphoneInUse: false, policy: policy(onDelay: 3), now: at(20)
        )
        #expect(resumed.intent == .doNothing)
        #expect(resumed.wakeAt == at(23))
    }

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
