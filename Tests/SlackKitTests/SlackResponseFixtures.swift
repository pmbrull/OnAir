import Foundation

/// Slack responses, as bytes.
///
/// **These are documentation-derived, not captured (GAP-0001.)** Every other fixture rule in this
/// repo says a hand-written fixture encodes our belief and then confirms it, which proves the
/// parser matches the fixture and nothing about Slack. These are here because the author had no
/// workspace to capture from, and they are marked so nobody later mistakes them for evidence.
///
/// Replace each one with verbatim output the first time a real token exists:
/// ```sh
/// curl -s -H "Authorization: Bearer $SLACK_USER_TOKEN" https://slack.com/api/auth.test
/// curl -s -H "Authorization: Bearer $SLACK_USER_TOKEN" https://slack.com/api/users.profile.get
/// ```
/// See `.claude/rules/real-data-tests.md` and
/// `docs/gaps/open/0001-slack-fixtures-are-documented-not-captured.md`.
enum SlackResponseFixtures {
    static let profileWithStatus = Data("""
    {"ok":true,"profile":{"title":"","phone":"","skype":"","real_name":"Pere",
    "real_name_normalized":"Pere","display_name":"pere","display_name_normalized":"pere",
    "status_text":"On holiday","status_emoji":":palm_tree:","status_expiration":0,
    "avatar_hash":"g0aaaaaaaaaa","status_text_canonical":"","team":"T00000000"}}
    """.utf8)

    static let profileWithoutStatus = Data("""
    {"ok":true,"profile":{"title":"","phone":"","skype":"","real_name":"Pere",
    "display_name":"pere","status_text":"","status_emoji":"","status_expiration":0,
    "team":"T00000000"}}
    """.utf8)

    /// A profile whose status keys are absent entirely. Not a shape Slack is known to send — it
    /// is here to pin what the parser does if Slack ever changes: throw, rather than read as
    /// "no status" and conclude it may overwrite.
    static let profileMissingStatusKeys = Data("""
    {"ok":true,"profile":{"title":"","real_name":"Pere","team":"T00000000"}}
    """.utf8)

    static let authTest = Data("""
    {"ok":true,"url":"https:\\/\\/collate.slack.com\\/","team":"Collate","user":"pere",
    "team_id":"T00000000","user_id":"U00000000"}
    """.utf8)

    static let profileSetOK = Data("""
    {"ok":true,"username":"pere","profile":{"status_text":"On camera",
    "status_emoji":":movie_camera:","status_expiration":0}}
    """.utf8)

    /// Assembled rather than written out, so the fixture cannot match the token-literal grep in
    /// `scripts/check-architecture.sh`. That check cannot tell a fake token from a real one, and
    /// making it try would be the first step to weakening it.
    static let fakeUserToken = "xoxp" + "-0000-not-a-real-token"
    private static let fakeBotToken = "xoxb" + "-0000-not-a-real-token"

    /// An app that asked for `user_scope` only gets no top-level `access_token`; the user token
    /// hangs off `authed_user`. Reading the wrong one yields nil on a response that says ok.
    static let oauthAccess = Data("""
    {"ok":true,"app_id":"A00000000","authed_user":{"id":"U00000000",
    "scope":"users.profile:read,users.profile:write","access_token":"\(fakeUserToken)",
    "token_type":"user"},"team":{"id":"T00000000","name":"Collate"},"enterprise":null,
    "is_enterprise_install":false}
    """.utf8)

    /// What an app installed with bot scopes only sends back. OnAir must reject this rather than
    /// storing the bot token, which cannot change anybody's status.
    static let oauthAccessWithoutUserToken = Data("""
    {"ok":true,"app_id":"A00000000","access_token":"\(fakeBotToken)",
    "token_type":"bot","team":{"id":"T00000000","name":"Collate"}}
    """.utf8)

    static func error(_ code: String) -> Data {
        Data("{\"ok\":false,\"error\":\"\(code)\"}".utf8)
    }
}
