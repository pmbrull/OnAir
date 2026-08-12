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
    public static func status(
        _ data: Data,
        status: Int,
        retryAfter: String? = nil
    ) throws -> UserStatus {
        let json = try envelope(data, status: status, retryAfter: retryAfter)
        guard let profile = json["profile"] as? [String: Any] else {
            throw SlackError.malformedResponse("no profile object")
        }
        guard let emoji = profile["status_emoji"] as? String,
              let text = profile["status_text"] as? String
        else {
            throw SlackError.malformedResponse("profile has no status_emoji/status_text")
        }
        return UserStatus(emoji: emoji, text: text)
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

    /// `oauth.v2.access`. The user token hangs off `authed_user`, **not** the top-level
    /// `access_token` — that one is the bot token, which an app requesting only `user_scope` does
    /// not even receive. Reading the wrong field yields `nil` on a response that says `ok: true`.
    public static func userAccessToken(
        _ data: Data,
        status: Int,
        retryAfter: String? = nil
    ) throws -> String {
        let json = try envelope(data, status: status, retryAfter: retryAfter)
        guard let authedUser = json["authed_user"] as? [String: Any] else {
            throw SlackError.malformedResponse("no authed_user object")
        }
        guard let token = authedUser["access_token"] as? String, !token.isEmpty else {
            throw SlackError.malformedResponse(
                "authed_user carried no access_token — was the app installed with user scopes?"
            )
        }
        return token
    }

    /// The body of `users.profile.set`.
    ///
    /// `status_expiration: 0` is sent explicitly rather than omitted: OnAir owns the whole status
    /// while it holds it, and leaving the key out lets an expiry set by something else survive
    /// underneath and clear the status at a time OnAir would then attribute to the user.
    public static func profileSetBody(_ status: UserStatus) throws -> Data {
        let payload: [String: Any] = [
            "profile": [
                "status_text": status.text,
                "status_emoji": status.emoji,
                "status_expiration": 0,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
