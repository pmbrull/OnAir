import Foundation

/// Everything that can go wrong talking to Slack, kept apart by what the user should *do* about
/// it. A failure that cannot be told from a rate limit ends up either retried forever or given up
/// on — this app has to distinguish the two.
public enum SlackError: Error, Sendable, Equatable {
    /// Slack answered `{"ok": false, "error": "<code>"}`.
    case api(code: String)
    /// HTTP 429. `retryAfter` is Slack's own `Retry-After` header in seconds.
    case rateLimited(retryAfter: TimeInterval)
    case http(status: Int)
    /// The body was not the shape this code knows. Carries what was expected, so a Slack schema
    /// change reads as a schema change rather than as a mystery.
    case malformedResponse(String)
    case transport(String)

    /// Retrying will not help; the user has to reconnect. Anything else is worth another attempt.
    public var requiresReconnect: Bool {
        guard case let .api(code) = self else { return false }
        return [
            "invalid_auth",
            "not_authed",
            "account_inactive",
            "token_revoked",
            "token_expired",
            "missing_scope",
            "no_permission",
        ].contains(code)
    }

    public var summary: String {
        switch self {
        case let .api(code):
            "Slack refused the call: \(code)"
        case let .rateLimited(retryAfter):
            "Slack is rate-limiting; retrying in \(Int(retryAfter.rounded()))s"
        case let .http(status):
            "Slack answered HTTP \(status)"
        case let .malformedResponse(detail):
            "Slack's answer was not the expected shape: \(detail)"
        case let .transport(detail):
            "Could not reach Slack: \(detail)"
        }
    }
}
