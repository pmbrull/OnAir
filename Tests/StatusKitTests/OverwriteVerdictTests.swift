import Foundation
@testable import StatusKit
import Testing

/// The override rule — the one the user is most likely to notice getting wrong, in either
/// direction: clobbering a status they typed, or refusing to set one over an empty profile.
@Suite("Overwrite verdict")
struct OverwriteVerdictTests {
    private func policy(overrideExisting: Bool) -> StatusPolicy {
        var rules = StatusPolicy.standard
        rules.overrideExistingStatus = overrideExisting
        return rules
    }

    @Test("an empty status is always writable")
    func emptyIsWritable() {
        #expect(policy(overrideExisting: false).verdict(forLive: .cleared) == .write)
        #expect(policy(overrideExisting: true).verdict(forLive: .cleared) == .write)
    }

    @Test("a status you set is left alone by default")
    func leftAloneByDefault() {
        let live = UserStatus(emoji: ":palm_tree:", text: "On holiday")
        #expect(policy(overrideExisting: false)
            .verdict(forLive: live) == .leaveAlone(.statusAlreadySet))
    }

    @Test("override writes over it")
    func overrideWrites() {
        let live = UserStatus(emoji: ":palm_tree:", text: "On holiday")
        #expect(policy(overrideExisting: true).verdict(forLive: live) == .write)
    }

    /// Slack lets either half stand alone, and both count as "you set something". An emoji with
    /// no text is the shape a one-click status picker produces, so it is the likely real case.
    @Test("either half alone counts as a status")
    func halfAStatusStillCounts() {
        let emojiOnly = UserStatus(emoji: ":palm_tree:", text: "")
        let textOnly = UserStatus(emoji: "", text: "On holiday")
        #expect(
            policy(overrideExisting: false).verdict(forLive: emojiOnly)
                == .leaveAlone(.statusAlreadySet)
        )
        #expect(
            policy(overrideExisting: false).verdict(forLive: textOnly)
                == .leaveAlone(.statusAlreadySet)
        )
    }
}

/// The shipped defaults are a product decision, so a change to one should have to be deliberate
/// rather than a diff nobody read.
@Suite("Status policy")
struct StatusPolicyTests {
    @Test("the shipped defaults")
    func defaults() {
        let standard = StatusPolicy.standard
        #expect(standard.watchCamera)
        #expect(!standard.watchMicrophone, "ADR-0011: mixers hold the microphone open")
        #expect(!standard.overrideExistingStatus)
        #expect(standard.onDelay == 3)
        #expect(standard.offDelay == 60)
        #expect(!standard.paused)
        #expect(standard.status.emoji == ":movie_camera:")
    }

    @Test("a policy round-trips")
    func roundTrip() throws {
        var original = StatusPolicy.standard
        original.offDelay = 120
        original.status = UserStatus(emoji: ":red_circle:", text: "On air")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(StatusPolicy.self, from: data) == original)
    }

    /// A policy written by an older build must not reset every other setting because one key is
    /// missing — which is what a plain synthesised `Decodable` would do.
    @Test("a policy from an older build keeps the keys it has")
    func forwardCompatibleDecode() throws {
        let older = Data("""
        {"status":{"emoji":":red_circle:","text":"On air"},"onDelay":9}
        """.utf8)
        let decoded = try JSONDecoder().decode(StatusPolicy.self, from: older)
        #expect(decoded.status == UserStatus(emoji: ":red_circle:", text: "On air"))
        #expect(decoded.onDelay == 9)
        #expect(decoded.offDelay == StatusPolicy.standard.offDelay)
        #expect(decoded.watchMicrophone == StatusPolicy.standard.watchMicrophone)
    }
}
