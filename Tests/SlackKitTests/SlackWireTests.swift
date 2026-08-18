import Foundation
@testable import SlackKit
import StatusKit
import Testing

@Suite("Slack wire format")
struct SlackWireTests {
    // MARK: - The envelope

    /// Slack answers HTTP 200 with `ok: false` for most failures, so a parser that trusted the
    /// status code would read every refusal as a success.
    @Test("a refusal at HTTP 200 is still a refusal")
    func refusalAtTwoHundred() {
        #expect(throws: SlackError.api(code: "invalid_auth")) {
            try SlackWire.envelope(
                SlackResponseFixtures.error("invalid_auth"),
                status: 200,
                retryAfter: nil
            )
        }
    }

    @Test("429 becomes a rate limit carrying Retry-After")
    func rateLimit() {
        #expect(throws: SlackError.rateLimited(retryAfter: 30)) {
            try SlackWire.envelope(Data("{}".utf8), status: 429, retryAfter: "30")
        }
    }

    /// Slack documents `Retry-After` on every 429, but a missing or unparseable header must not
    /// turn into a zero-second retry that hammers the endpoint that just asked us to stop.
    @Test("a 429 with no usable Retry-After still backs off")
    func rateLimitWithoutHeader() {
        #expect(throws: SlackError.rateLimited(retryAfter: 60)) {
            try SlackWire.envelope(Data("{}".utf8), status: 429, retryAfter: nil)
        }
        #expect(throws: SlackError.rateLimited(retryAfter: 60)) {
            try SlackWire.envelope(Data("{}".utf8), status: 429, retryAfter: "soon")
        }
    }

    @Test("a non-JSON body is malformed, not a crash")
    func nonJSONBody() {
        #expect(throws: SlackError.self) {
            try SlackWire.envelope(Data("<html>502</html>".utf8), status: 502, retryAfter: nil)
        }
    }

    @Test("ok false with no error code is malformed")
    func okFalseWithoutCode() {
        #expect(throws: SlackError.malformedResponse("ok was false with no error code")) {
            try SlackWire.envelope(Data("{\"ok\":false}".utf8), status: 200, retryAfter: nil)
        }
    }

    // MARK: - The status

    @Test("a profile with a status reads both halves")
    func statusIsRead() throws {
        let live = try SlackWire.status(SlackResponseFixtures.profileWithStatus, status: 200)
        #expect(live.status == UserStatus(emoji: ":palm_tree:", text: "On holiday"))
        #expect(!live.status.isCleared)
        #expect(live.expiresAt == 0)
    }

    @Test("a profile with no status reads as cleared")
    func emptyStatus() throws {
        let live = try SlackWire.status(SlackResponseFixtures.profileWithoutStatus, status: 200)
        #expect(live.status.isCleared)
    }

    /// The status this feature exists for: an integration's, carrying the clock that will clear
    /// it. Dropping the expiry here is what leaves someone "In a meeting" all day (ADR-0015).
    @Test("an integration's status carries its expiry off the wire")
    func expiringStatusIsRead() throws {
        let live = try SlackWire.status(
            SlackResponseFixtures.profileWithExpiringStatus, status: 200
        )
        #expect(live.status.text == "In a meeting • Google Calendar")
        #expect(live.expiresAt == 1_700_003_600)
    }

    @Test("a profile missing status_expiration throws rather than reading as never")
    func missingExpirationThrows() {
        #expect(throws: SlackError.malformedResponse("profile has no status_expiration")) {
            try SlackWire.status(SlackResponseFixtures.profileMissingExpiration, status: 200)
        }
    }

    /// A nonsense value must not collapse into the permissive answer. "Never expires" is the
    /// reading that writes a status back with nothing left to clear it (ADR-0015).
    @Test("a negative status_expiration is malformed, not never")
    func negativeExpirationThrows() {
        #expect(throws: SlackError.malformedResponse("status_expiration is negative")) {
            try SlackWire.status(SlackResponseFixtures.profileWithNegativeExpiration, status: 200)
        }
    }

    /// The load-bearing one. If missing keys read as "cleared", the override rule concludes there
    /// is nothing to protect and OnAir writes over a status it never actually saw.
    @Test("a profile missing the status keys throws rather than reading as cleared")
    func missingStatusKeysThrow() {
        #expect(throws: SlackError.self) {
            try SlackWire.status(SlackResponseFixtures.profileMissingStatusKeys, status: 200)
        }
    }

    @Test("a refusal on users.profile.get is not an empty status")
    func refusalIsNotEmptyStatus() {
        #expect(throws: SlackError.api(code: "ratelimited")) {
            try SlackWire.status(SlackResponseFixtures.error("ratelimited"), status: 200)
        }
    }

    // MARK: - Identity

    @Test("auth.test yields the user and the workspace")
    func identity() throws {
        let identity = try SlackWire.identity(SlackResponseFixtures.authTest, status: 200)
        #expect(identity.userID == "U00000000")
        #expect(identity.userName == "pere")
        #expect(identity.teamName == "Collate")
    }

    // MARK: - The token exchange

    /// A fixed instant, so `expires_in` — a duration — can be asserted as the absolute date OnAir
    /// actually stores.
    private static let noon = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("the user token comes from authed_user")
    func userToken() throws {
        let credential = try SlackWire.credential(SlackResponseFixtures.oauthAccess, status: 200)
        #expect(credential.accessToken == SlackResponseFixtures.fakeUserToken)
        // The pre-ADR-0020 shape: no rotation, so nothing to schedule and nothing to renew.
        #expect(credential.expiresAt == nil)
        #expect(credential.refreshToken == nil)
    }

    /// What the shared app issues, and the reason ADR-0020 exists.
    @Test("a rotating exchange carries the expiry and the refresh token")
    func rotatingExchange() throws {
        let credential = try SlackWire.credential(
            SlackResponseFixtures.oauthAccessRotating,
            status: 200,
            now: Self.noon
        )
        #expect(credential.accessToken == SlackResponseFixtures.fakeUserToken)
        #expect(credential.refreshToken == SlackResponseFixtures.fakeRefreshToken)
        #expect(credential.expiresAt == Self.noon.addingTimeInterval(43200))
    }

    /// Slack documents the renewal response for bot tokens, where the token is at the top level.
    /// Whether the user case wraps it in `authed_user` is unmeasured (GAP-0002), so both are
    /// accepted and both are pinned — the failure otherwise is a renewal that parses as malformed
    /// and a connection that dies at the twelve-hour mark for no visible reason.
    @Test("a renewal is read at the top level or under authed_user")
    func renewalShapes() throws {
        for (name, data) in [
            ("top level", SlackResponseFixtures.oauthRenewalTopLevel),
            ("authed_user", SlackResponseFixtures.oauthRenewalUnderAuthedUser),
        ] {
            let credential = try SlackWire.credential(data, status: 200, now: Self.noon)
            #expect(
                credential.accessToken == SlackResponseFixtures.fakeUserToken,
                "\(name) shape lost the access credential"
            )
            #expect(
                credential.refreshToken == SlackResponseFixtures.fakeRefreshToken,
                "\(name) shape lost the renewal credential"
            )
            #expect(
                credential.expiresAt == Self.noon.addingTimeInterval(43200),
                "\(name) shape lost the expiry"
            )
        }
    }

    /// The dead end: it expires, and nothing can renew it. Parsing must preserve both facts, since
    /// the pair is what makes OnAir warn now instead of failing in twelve hours.
    @Test("an expiry with no refresh token parses, and says so")
    func expiringWithoutRefresh() throws {
        let credential = try SlackWire.credential(
            SlackResponseFixtures.oauthAccessExpiringWithoutRefresh,
            status: 200,
            now: Self.noon
        )
        #expect(credential.expiresAt == Self.noon.addingTimeInterval(43200))
        #expect(credential.refreshToken == nil)
        #expect(
            TokenRefresh.plan(for: credential, now: Self.noon)
                == .cannotRenew(expiresAt: Self.noon.addingTimeInterval(43200))
        )
    }

    @Test("a quoted expires_in is a number, an unreadable one is malformed")
    func expiryShapes() throws {
        let quoted = try SlackWire.credential(
            SlackResponseFixtures.oauthAccessQuotedExpiry,
            status: 200,
            now: Self.noon
        )
        #expect(quoted.expiresAt == Self.noon.addingTimeInterval(43200))
        // Never "nil, so it never expires": that reading disables the renewal loop silently.
        #expect(throws: SlackError.self) {
            try SlackWire.credential(SlackResponseFixtures.oauthAccessUnreadableExpiry, status: 200)
        }
    }

    /// Installing the app with bot scopes instead of user scopes is the likeliest setup mistake.
    /// It must fail loudly here rather than storing a token that cannot set a status.
    @Test("a response with only a bot token is rejected")
    func botTokenRejected() {
        #expect(throws: SlackError.self) {
            try SlackWire.credential(
                SlackResponseFixtures.oauthAccessWithoutUserToken, status: 200
            )
        }
    }

    @Test("a bad code surfaces Slack's own error")
    func badCode() {
        #expect(throws: SlackError.api(code: "invalid_code")) {
            try SlackWire.credential(SlackResponseFixtures.error("invalid_code"), status: 200)
        }
    }

    // MARK: - What gets written

    @Test("the profile body carries both halves and an explicit zero expiry")
    func profileSetBody() throws {
        let body = try SlackWire.profileSetBody(UserStatus(
            emoji: ":movie_camera:",
            text: "On camera"
        ))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let profile = try #require(json["profile"] as? [String: Any])
        #expect(profile["status_emoji"] as? String == ":movie_camera:")
        #expect(profile["status_text"] as? String == "On camera")
        // Omitting this lets an expiry set by something else survive underneath and clear the
        // status at a moment OnAir would then attribute to the user.
        #expect(profile["status_expiration"] as? Int == 0)
    }

    /// The other half of ADR-0015: OnAir's own status never expires, but a restore must put back
    /// the expiry the previous status arrived with, or nothing will ever clear it.
    @Test("a restore can carry someone else's expiry back")
    func profileSetBodyWithExpiry() throws {
        let body = try SlackWire.profileSetBody(
            UserStatus(emoji: ":spiral_calendar_pad:", text: "In a meeting"),
            expiresAt: 1_700_003_600
        )
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let profile = try #require(json["profile"] as? [String: Any])
        #expect(profile["status_expiration"] as? Int == 1_700_003_600)
    }

    @Test("clearing is an empty write, since Slack has no delete")
    func clearingBody() throws {
        let body = try SlackWire.profileSetBody(.cleared)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let profile = try #require(json["profile"] as? [String: Any])
        #expect(profile["status_emoji"] as? String == "")
        #expect(profile["status_text"] as? String == "")
    }

    // MARK: - The snooze (ADR-0013)

    @Test("a running snooze reads back with its endtime")
    func snoozeReads() throws {
        let state = try SlackWire.snoozeState(SlackResponseFixtures.dndInfoSnoozing, status: 200)
        #expect(state == SnoozeState(isSnoozing: true, endsAt: 1_450_373_897))
    }

    /// The documented quirk the parser leans on: the snooze keys are absent when not snoozing —
    /// unlike the profile, absence here genuinely means "off", not "schema changed".
    @Test("absent snooze keys mean not snoozing")
    func absentSnoozeKeysMeanOff() throws {
        let state = try SlackWire.snoozeState(SlackResponseFixtures.dndInfoNotSnoozing, status: 200)
        #expect(state == .off)
    }

    @Test("setSnooze's reply carries the endtime the ownership rule will compare")
    func setSnoozeReads() throws {
        let state = try SlackWire.snoozeState(SlackResponseFixtures.dndSetSnooze, status: 200)
        #expect(state.isSnoozing)
        #expect(state.endsAt == 1_450_373_897)
    }

    /// Snoozing with no endtime would corrupt the exact-match ownership rule, so it throws
    /// rather than inventing a value.
    @Test("snoozing with no endtime is malformed, not guessed")
    func snoozeWithoutEndtime() {
        #expect(throws: SlackError.malformedResponse("snooze_enabled with no snooze_endtime")) {
            try SlackWire.snoozeState(
                Data("{\"ok\":true,\"snooze_enabled\":true}".utf8),
                status: 200
            )
        }
    }

    @Test("a refusal on dnd.info is an error, not 'not snoozing'")
    func dndRefusalIsNotOff() {
        #expect(throws: SlackError.api(code: "missing_scope")) {
            try SlackWire.snoozeState(SlackResponseFixtures.error("missing_scope"), status: 200)
        }
    }

    // MARK: - Which failures need a human

    @Test("only the credential failures ask for a reconnect")
    func reconnectClassification() {
        #expect(SlackError.api(code: "invalid_auth").requiresReconnect)
        #expect(SlackError.api(code: "token_revoked").requiresReconnect)
        #expect(SlackError.api(code: "missing_scope").requiresReconnect)
        #expect(!SlackError.api(code: "ratelimited").requiresReconnect)
        #expect(!SlackError.api(code: "service_unavailable").requiresReconnect)
        #expect(!SlackError.rateLimited(retryAfter: 30).requiresReconnect)
        #expect(!SlackError.transport("offline").requiresReconnect)
    }
}
