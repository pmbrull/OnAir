import Foundation
import StatusKit

/// Who the stored token belongs to. Shown in Settings so "connected" can be checked against the
/// account you meant, which matters the moment you have two workspaces.
public struct SlackIdentity: Sendable, Equatable {
    public let userID: String
    public let userName: String
    public let teamName: String

    public init(userID: String, userName: String, teamName: String) {
        self.userID = userID
        self.userName = userName
        self.teamName = teamName
    }
}

/// Decoding, apart from the network.
///
/// Every function here turns bytes into a value or throws. Nothing does I/O, so the tests feed it
/// captured Slack responses directly — which is the only way to find out that our belief about
/// Slack's shape is wrong (`.claude/rules/real-data-tests.md`).
public enum SlackWire {
    /// Slack answers HTTP 200 with `{"ok": false}` for most failures, so the status code alone
    /// says almost nothing and the envelope has to be read every time.
    public static func envelope(
        _ data: Data,
        status: Int,
        retryAfter: String?
    ) throws -> [String: Any] {
        if status == 429 {
            let seconds = retryAfter.flatMap(TimeInterval.init) ?? 60
            throw SlackError.rateLimited(retryAfter: seconds)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            throw SlackError.malformedResponse("expected a JSON object")
        }
        guard json["ok"] as? Bool == true else {
            guard let code = json["error"] as? String else {
                throw SlackError.malformedResponse("ok was false with no error code")
            }
            throw SlackError.api(code: code)
        }
        guard (200 ..< 300).contains(status) else {
            throw SlackError.http(status: status)
        }
        return json
    }

    /// `users.profile.get`. A profile with no status has both fields present and empty; a missing
    /// key is a schema change, not an empty status, so it throws rather than reading as cleared —
    /// treating it as cleared would make OnAir believe it may overwrite a status it never saw.
    ///
    /// `status_expiration` is read for the same reason and held to the same bar: "never expires"
    /// and "Slack did not tell us" must not be the same value, because OnAir writes this field
    /// back on a restore and defaulting it to `0` is what strands a Google Calendar status forever
    /// (ADR-0015). Its presence is documentation-derived — GAP-0001.
    public static func status(
        _ data: Data,
        status: Int,
        retryAfter: String? = nil
    ) throws -> LiveStatus {
        let json = try envelope(data, status: status, retryAfter: retryAfter)
        guard let profile = json["profile"] as? [String: Any] else {
            throw SlackError.malformedResponse("no profile object")
        }
        guard let emoji = profile["status_emoji"] as? String,
              let text = profile["status_text"] as? String
        else {
            throw SlackError.malformedResponse("profile has no status_emoji/status_text")
        }
        guard let expiration = profile["status_expiration"] as? Int else {
            throw SlackError.malformedResponse("profile has no status_expiration")
        }
        // A negative expiry is not "never": folding it into `0` would be the permissive reading —
        // the one that writes a status back with nothing left to clear it.
        guard expiration >= 0 else {
            throw SlackError.malformedResponse("status_expiration is negative")
        }
        return LiveStatus(
            status: UserStatus(emoji: emoji, text: text),
            expiresAt: expiration
        )
    }

    /// `auth.test`.
    public static func identity(
        _ data: Data,
        status: Int,
        retryAfter: String? = nil
    ) throws -> SlackIdentity {
        let json = try envelope(data, status: status, retryAfter: retryAfter)
        guard let userID = json["user_id"] as? String,
              let userName = json["user"] as? String,
              let teamName = json["team"] as? String
        else {
            throw SlackError.malformedResponse("auth.test lacked user_id/user/team")
        }
        return SlackIdentity(userID: userID, userName: userName, teamName: teamName)
    }

    /// `oauth.v2.access`, for both of the things it does: the first exchange, and every renewal
    /// after it (ADR-0020).
    ///
    /// `now` is injected because `expires_in` is a *duration*: the absolute instant OnAir stores is
    /// derived here, and a test that could not fix the clock could only assert the arithmetic
    /// against itself.
    public static func credential(
        _ data: Data,
        status: Int,
        retryAfter: String? = nil,
        now: Date = Date()
    ) throws -> SlackCredential {
        let json = try envelope(data, status: status, retryAfter: retryAfter)
        let carrier = try tokenCarrier(json)
        guard let accessToken = carrier["access_token"] as? String, !accessToken.isEmpty else {
            throw SlackError.malformedResponse(
                "no access_token — was the app installed with user scopes?"
            )
        }
        return try SlackCredential(
            accessToken: accessToken,
            expiresAt: expiry(carrier, now: now),
            refreshToken: renewalToken(carrier)
        )
    }

    /// Which object the user token is in.
    ///
    /// The first exchange hangs it off `authed_user`, **not** the top-level `access_token` — that
    /// one is the bot token, which an app requesting only `user_scope` does not even receive.
    /// Slack documents the *renewal* response only for the bot case, where the token is at the top
    /// level; whether the user case wraps it in `authed_user` is unmeasured (GAP-0002). Both are
    /// accepted, and if neither is there the error names both, because the alternative is
    /// "connect is broken" with nothing pointing at the shape that changed.
    private static func tokenCarrier(_ json: [String: Any]) throws -> [String: Any] {
        if let authedUser = json["authed_user"] as? [String: Any] {
            return authedUser
        }
        guard json["access_token"] is String else {
            throw SlackError.malformedResponse(
                "neither an authed_user object nor a top-level access_token"
            )
        }
        // A bot token at the top level is not a near-enough substitute: it cannot set anybody's
        // status, so accepting it would store a credential that fails on the first real call.
        guard json["token_type"] as? String == "user" else {
            throw SlackError.malformedResponse(
                "the only credential in the response is a bot one; OnAir asks for user scopes only"
            )
        }
        return json
    }

    /// Absent means Slack issued a non-expiring credential — the documented behaviour with token
    /// rotation off. Present but unreadable is a schema change, and it throws: reading it as
    /// "never expires" would disable the whole renewal loop silently, which is the failure that
    /// sends the user back to Connect every morning without saying why.
    private static func expiry(_ carrier: [String: Any], now: Date) throws -> Date? {
        guard let raw = carrier["expires_in"] else { return nil }
        let seconds: Int
        if let number = raw as? Int {
            seconds = number
        } else if let text = raw as? String, let parsed = Int(text) {
            // Slack's examples show a bare number; some of its docs quote it. Accepting both costs
            // one branch, and guessing wrong costs a renewal loop that never runs.
            seconds = parsed
        } else {
            throw SlackError
                .malformedResponse("expires_in was neither a number nor a numeric string")
        }
        guard seconds > 0 else {
            throw SlackError.malformedResponse("expires_in was not a positive number of seconds")
        }
        return now.addingTimeInterval(TimeInterval(seconds))
    }

    private static func renewalToken(_ carrier: [String: Any]) throws -> String? {
        guard let raw = carrier["refresh_token"] else { return nil }
        guard let value = raw as? String, !value.isEmpty else {
            throw SlackError.malformedResponse("refresh_token was present but not a usable string")
        }
        return value
    }

    /// `dnd.info` and `dnd.setSnooze` share this shape. One documented quirk the parser leans on:
    /// `snooze_enabled` and `snooze_endtime` are present **only while a snooze is active** — an
    /// absent key here genuinely means "not snoozing", unlike the profile, where an absent status
    /// key means the schema changed (GAP-0001 marks this as documentation-derived).
    public static func snoozeState(
        _ data: Data,
        status: Int,
        retryAfter: String? = nil
    ) throws -> SnoozeState {
        let json = try envelope(data, status: status, retryAfter: retryAfter)
        guard json["snooze_enabled"] as? Bool == true else { return .off }
        guard let endtime = json["snooze_endtime"] as? Int else {
            // Snoozing with no endtime is a shape Slack does not document; inventing one would
            // corrupt the ownership rule, which compares endtimes exactly (ADR-0013).
            throw SlackError.malformedResponse("snooze_enabled with no snooze_endtime")
        }
        return SnoozeState(isSnoozing: true, endsAt: endtime)
    }

    /// The body of `users.profile.set`.
    ///
    /// `status_expiration` is always sent explicitly rather than omitted: omitting it lets an
    /// expiry set by something else survive underneath and clear the status at a time OnAir would
    /// then attribute to the user.
    ///
    /// It defaults to `0` because OnAir's own status never expires (ADR-0009). The one caller that
    /// passes anything else is the restore, putting back the expiry the previous status arrived
    /// with — its own clock, not one OnAir chose (ADR-0015).
    public static func profileSetBody(_ status: UserStatus, expiresAt: Int = 0) throws -> Data {
        let payload: [String: Any] = [
            "profile": [
                "status_text": status.text,
                "status_emoji": status.emoji,
                "status_expiration": expiresAt,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
