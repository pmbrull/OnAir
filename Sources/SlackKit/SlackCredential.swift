import Foundation

/// What `oauth.v2.access` hands back, whole.
///
/// Before ADR-0020 this was a `String`, because Slack's documentation says an OAuth token does not
/// expire. The shared app's tokens do: `make doctor-slack` on 2026-08-18 answered `token_expired`
/// against a credential minted five days earlier, which is what a **rotating** token does after
/// twelve hours. The two fields beside the access token are what makes that survivable without a
/// human.
///
/// The kit still stores nothing — this is a value handed to the app, whose `TokenStore` puts it in
/// the Keychain and nowhere else (invariant A4, ADR-0006).
public struct SlackCredential: Sendable, Equatable {
    public let accessToken: String

    /// `nil` means Slack sent no `expires_in` — the documented behaviour for an app with token
    /// rotation off. Never a sentinel date: "this never expires" and "Slack did not say" are
    /// different facts, and only one of them means OnAir has nothing to schedule.
    public let expiresAt: Date?

    /// `nil` means Slack sent no `refresh_token`. Paired with an `expiresAt` that is *not* nil it
    /// describes a credential nothing can renew — a state OnAir reports at once rather than
    /// discovering at the deadline (`.claude/rules/no-silent-fallbacks.md`).
    public let refreshToken: String?

    public init(accessToken: String, expiresAt: Date? = nil, refreshToken: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
    }

    // MARK: - The half that is persisted separately

    /// Everything except the access token itself.
    ///
    /// It lives in its own Keychain item (ADR-0020) because the access token's item is read at
    /// every launch by code that shipped before this existed: changing the *shape* of that item
    /// would log out every installed copy on upgrade, to save one Keychain round trip.
    public struct Renewal: Sendable, Equatable {
        public let refreshToken: String?
        public let expiresAt: Date?

        public init(refreshToken: String?, expiresAt: Date?) {
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }
    }

    /// What decoding a stored renewal item found. Three answers, not two, because they call for
    /// three different things to be said out loud:
    ///
    /// - `absent` — no item at all. Every credential stored before ADR-0020 looks like this, and
    ///   nothing is known about whether it expires. It is **not** the same as a credential Slack
    ///   said would never expire, which is why an empty record is still a record.
    /// - `unreadable` — an item that will not decode. A bug in this app rather than a state Slack
    ///   put anyone in, and `doctor` says so.
    /// - `present` — what Slack sent, including "neither an expiry nor a refresh token".
    public enum RenewalRecord: Sendable, Equatable {
        case absent
        case unreadable
        case present(Renewal)
    }

    /// Always written, even when both halves are empty: an empty record is the durable difference
    /// between "Slack issued no expiry" and "nobody ever looked", and reporting the second as the
    /// first is exactly the invented value `.claude/rules/no-silent-fallbacks.md` forbids.
    public var renewal: Renewal {
        Renewal(refreshToken: refreshToken, expiresAt: expiresAt)
    }

    /// JSON rather than a delimiter-joined string: the two fields are optional independently, and
    /// a format where absence is a position is a format that goes wrong silently.
    public static func encode(_ renewal: Renewal) throws -> Data {
        var payload: [String: Any] = [:]
        if let value = renewal.refreshToken {
            payload["refresh_token"] = value
        }
        if let expiresAt = renewal.expiresAt {
            payload["expires_at"] = Int(expiresAt.timeIntervalSince1970)
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Pure, so the one thing OnAir persists in a shape of its own is pinned by tests rather than
    /// by an upgrader finding out — the same bar `parseStoredClientID` is held to.
    public static func decodeRenewal(_ data: Data) -> RenewalRecord {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            return .unreadable
        }
        var token: String?
        if let raw = json["refresh_token"] {
            guard let value = raw as? String, !value.isEmpty else { return .unreadable }
            token = value
        }
        var expiresAt: Date?
        if let raw = json["expires_at"] {
            guard let seconds = raw as? Int, seconds > 0 else { return .unreadable }
            expiresAt = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        // `{}` is `present`, not `absent`: it is OnAir recording that Slack sent neither field.
        // Only a missing item is `absent`, and that is the caller's answer to give.
        return .present(Renewal(refreshToken: token, expiresAt: expiresAt))
    }
}

/// When a credential has to be renewed, as a pure function.
///
/// It lives in the kit rather than the app for the reason invariant A3 exists: this decides
/// *whether* OnAir talks to Slack behind the user's back, and in the app target nothing could
/// assert on it. It is in `SlackKit` rather than `StatusKit` because it is about a credential and
/// says nothing about a status.
public enum TokenRefresh {
    /// Renew five minutes early. Slack's own advice is to refresh *before* `expires_in`, and the
    /// window has to cover a call that starts just under the wire: a status applied at expiry minus
    /// one second would otherwise fail, retry, and only then renew — with the camera already on.
    public static let skew: TimeInterval = 300

    public enum Plan: Sendable, Equatable {
        /// Slack named no expiry. Nothing to schedule, and nothing to worry about.
        case noExpiry
        /// Past the skew — renew before the next call.
        case refreshNow
        /// Not yet; wake at this instant. Always `expiry - skew`, never the expiry itself.
        case refreshAt(Date)
        /// It expires and there is no refresh token: only a human can fix this, and they should be
        /// told now rather than at the deadline.
        case cannotRenew(expiresAt: Date)
    }

    public static func plan(
        for credential: SlackCredential,
        now: Date,
        skew: TimeInterval = TokenRefresh.skew
    ) -> Plan {
        guard let expiresAt = credential.expiresAt else { return .noExpiry }
        guard credential.refreshToken != nil else { return .cannotRenew(expiresAt: expiresAt) }
        let due = expiresAt.addingTimeInterval(-skew)
        return now >= due ? .refreshNow : .refreshAt(due)
    }
}
