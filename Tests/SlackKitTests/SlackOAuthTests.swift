import Foundation
@testable import SlackKit
import Testing

@Suite("Slack OAuth")
struct SlackOAuthTests {
    @Test("the authorize URL asks for user scopes and carries the state")
    func authorizeURL() throws {
        let url = try #require(SlackOAuth.authorizationURL(
            clientID: "123.456",
            redirectURI: SlackOAuth.redirectURI(),
            state: "abc123"
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(components.host == "slack.com")
        #expect(components.path == "/oauth/v2/authorize")
        #expect(items["client_id"] == "123.456")
        #expect(items["state"] == "abc123")
        #expect(items["redirect_uri"] == "https://localhost:51234/callback")
        // `scope` would ask for a bot token, which cannot set anybody's status.
        #expect(items["scope"] == nil)
        #expect(items["user_scope"] == "users.profile:read,users.profile:write")
    }

    /// Slack refuses to register an `http://` redirect URL at all, which is the entire reason the
    /// loopback listener speaks TLS (ADR-0005). A change here silently breaks Connect.
    @Test("the redirect URI is https on loopback")
    func redirectURI() {
        #expect(SlackOAuth.redirectURI() == "https://localhost:51234/callback")
        #expect(SlackOAuth.redirectURI(port: 9999) == "https://localhost:9999/callback")
        #expect(SlackOAuth.redirectURI().hasPrefix("https://"))
    }

    @Test("the state is long and does not repeat")
    func state() {
        let first = SlackOAuth.newState()
        #expect(first.count == 64, "256 bits, hex-encoded")
        let isHex = first.allSatisfy(\.isHexDigit)
        #expect(isHex)
        let many = Set((0 ..< 50).map { _ in SlackOAuth.newState() })
        #expect(many.count == 50)
    }

    /// `URLComponents` leaves `:` and `/` unescaped in a query. That is legal in a URL and wrong
    /// in a form body — and `redirect_uri` is made of almost nothing else.
    @Test("form encoding escapes the reserved characters URLComponents leaves alone")
    func formEncoding() {
        let encoded = SlackOAuth.formEncoded([
            ("redirect_uri", "https://localhost:51234/callback"),
            ("code", "1234.5678.abc"),
        ])
        #expect(encoded ==
            "redirect_uri=https%3A%2F%2Flocalhost%3A51234%2Fcallback&code=1234.5678.abc")
        #expect(!encoded.contains("://"))
    }

    @Test("a session refuses to start without both halves of the client credentials")
    func incompleteCredentials() {
        #expect(throws: SlackOAuthSession.Failure.incompleteCredentials) {
            try SlackOAuthSession(
                credentials: SlackOAuth.Credentials(clientID: "123.456", clientSecret: "   "),
                supportDirectory: FileManager.default.temporaryDirectory
            )
        }
    }
}
