import Foundation
@testable import SlackKit
import Testing

/// The rule that decides whether OnAir talks to Slack behind the user's back (ADR-0020). It is a
/// pure function precisely so these cases exist: in the app target, "renews five minutes early"
/// would be an `if` nothing could assert on (A3).
@Suite("Token renewal")
struct TokenRefreshTests {
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func credential(
        expiresIn seconds: TimeInterval?,
        renewable: Bool = true,
        from now: Date
    ) -> SlackCredential {
        SlackCredential(
            accessToken: "not-a-real-credential",
            expiresAt: seconds.map { now.addingTimeInterval($0) },
            refreshToken: renewable ? "not-a-real-renewal" : nil
        )
    }

    /// A credential Slack named no expiry for is the pre-rotation case, and the documented
    /// behaviour with token rotation off. Nothing to schedule — and scheduling something anyway
    /// would mean guessing a lifetime nobody told us.
    @Test("no expiry means nothing to do")
    func noExpiry() {
        let plan = TokenRefresh.plan(
            for: credential(expiresIn: nil, from: noon),
            now: noon
        )
        #expect(plan == .noExpiry)
    }

    @Test("a live credential schedules its renewal one skew early")
    func schedulesEarly() {
        let plan = TokenRefresh.plan(
            for: credential(expiresIn: 43200, from: noon),
            now: noon
        )
        #expect(plan == .refreshAt(noon.addingTimeInterval(43200 - TokenRefresh.skew)))
    }

    /// The boundary is the point of the skew: a call starting one second inside the window must
    /// renew *first*, not fail, retry and renew with the camera already on.
    @Test("the skew boundary is due, not scheduled")
    func boundaryIsDue() {
        let expiring = credential(expiresIn: TokenRefresh.skew, from: noon)
        #expect(TokenRefresh.plan(for: expiring, now: noon) == .refreshNow)
        #expect(
            TokenRefresh.plan(for: expiring, now: noon.addingTimeInterval(-1))
                == .refreshAt(noon)
        )
    }

    /// The state the laptop wakes up in: expired hours ago, refresh token still good.
    @Test("an already-expired credential is due, not hopeless")
    func expiredIsDue() {
        let plan = TokenRefresh.plan(
            for: credential(expiresIn: -3600, from: noon),
            now: noon
        )
        #expect(plan == .refreshNow)
    }

    @Test("an expiry with nothing to renew it is reported, not scheduled")
    func cannotRenew() {
        let plan = TokenRefresh.plan(
            for: credential(expiresIn: 43200, renewable: false, from: noon),
            now: noon
        )
        #expect(plan == .cannotRenew(expiresAt: noon.addingTimeInterval(43200)))
    }
}

/// The one shape OnAir invents for itself, so it is pinned here rather than by an upgrader finding
/// out — the bar `parseStoredClientID` set.
@Suite("The stored renewal record")
struct RenewalRecordTests {
    private let expiry = Date(timeIntervalSince1970: 1_700_043_200)

    @Test("a full record survives a round trip")
    func roundTrip() throws {
        let renewal = SlackCredential.Renewal(
            refreshToken: "not-a-real-renewal",
            expiresAt: expiry
        )
        let decoded = try SlackCredential.decodeRenewal(SlackCredential.encode(renewal))
        #expect(decoded == .present(renewal))
    }

    /// Both halves are optional independently: a credential can expire with nothing to renew it,
    /// and — if Slack ever sends one — carry a refresh token with no expiry.
    @Test("either half alone survives a round trip")
    func halvesRoundTrip() throws {
        let expiryOnly = SlackCredential.Renewal(refreshToken: nil, expiresAt: expiry)
        #expect(
            try SlackCredential.decodeRenewal(SlackCredential.encode(expiryOnly))
                == .present(expiryOnly)
        )
        let renewalOnly = SlackCredential.Renewal(
            refreshToken: "not-a-real-renewal",
            expiresAt: nil
        )
        #expect(
            try SlackCredential.decodeRenewal(SlackCredential.encode(renewalOnly))
                == .present(renewalOnly)
        )
    }

    /// The distinction `doctor` prints. "Slack sent neither field" is a fact worth an item;
    /// "nobody ever looked" — every credential stored before ADR-0020 — is a different one, and
    /// reporting the second as the first is an invented value
    /// (`.claude/rules/no-silent-fallbacks.md`).
    @Test("a credential with nothing to renew still records that Slack sent nothing")
    func emptyRecordIsStillARecord() throws {
        let plain = SlackCredential(accessToken: "not-a-real-credential")
        let empty = SlackCredential.Renewal(refreshToken: nil, expiresAt: nil)
        #expect(plain.renewal == empty)
        #expect(
            try SlackCredential.decodeRenewal(SlackCredential.encode(plain.renewal))
                == .present(empty)
        )
    }

    /// `unreadable` is a separate answer from `absent` on purpose: both leave OnAir unable to
    /// renew, only one of them is a bug in this app, and `doctor` prints which
    /// (`.claude/rules/no-silent-fallbacks.md`).
    @Test("a corrupt record is unreadable, never an empty one")
    func corruptIsUnreadable() {
        #expect(SlackCredential.decodeRenewal(Data("not json".utf8)) == .unreadable)
        #expect(SlackCredential.decodeRenewal(Data("[]".utf8)) == .unreadable)
        #expect(
            SlackCredential.decodeRenewal(Data(#"{"expires_at":-5}"#.utf8)) == .unreadable
        )
        #expect(
            SlackCredential.decodeRenewal(Data(#"{"refresh_token":""}"#.utf8)) == .unreadable
        )
        // `absent` is the *caller's* answer when there is no item at all, so it is not one this
        // decoder can return: `{}` is a record saying Slack sent neither field.
        #expect(
            SlackCredential.decodeRenewal(Data("{}".utf8))
                == .present(SlackCredential.Renewal(refreshToken: nil, expiresAt: nil))
        )
    }

    /// Seconds, not a formatted date: a locale-dependent string in a Keychain item written on one
    /// machine and read on another is a bug waiting for a holiday.
    @Test("the record stores whole seconds since the epoch")
    func storesEpochSeconds() throws {
        let data = try SlackCredential.encode(
            SlackCredential.Renewal(refreshToken: nil, expiresAt: expiry)
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["expires_at"] as? Int == 1_700_043_200)
    }
}
