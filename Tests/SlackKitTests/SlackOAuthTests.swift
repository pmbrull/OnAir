import Foundation
@testable import SlackKit
import Testing

@Suite("Slack OAuth")
struct SlackOAuthTests {
    @Test("the authorize URL asks for user scopes and carries the state and the challenge")
    func authorizeURL() throws {
        let pkce = PKCE()
        let url = try #require(SlackOAuth.authorizationURL(
            clientID: "123.456",
            redirectURI: SlackOAuth.redirectURI(),
            state: "abc123",
            pkce: pkce
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
        #expect(items["user_scope"] == "users.profile:read,users.profile:write,dnd:read,dnd:write")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        // The verifier is the secret half; on the authorize URL it would be visible to the
        // browser, history, and every extension — exactly what PKCE exists to avoid.
        #expect(!(url.absoluteString.contains(pkce.verifier)))
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

    /// The acceptance criterion of ADR-0012, as a test: possession of the verifier replaces the
    /// secret, so the exchange body carries `code_verifier` and no `client_secret` — ever again.
    @Test("the exchange proves the verifier and sends no secret")
    func exchangeBody() {
        let pkce = PKCE()
        let body = SlackOAuth.exchangeBody(
            code: "1234.5678.abc",
            clientID: "123.456",
            pkce: pkce,
            redirectURI: SlackOAuth.redirectURI()
        )
        #expect(body.contains("code_verifier=\(pkce.verifier)"))
        #expect(body.contains("client_id=123.456"))
        #expect(body.contains("code=1234.5678.abc"))
        #expect(!body.contains("client_secret"))
    }

    @Test("a session refuses to start without a client id")
    func missingClientID() {
        #expect(throws: SlackOAuthSession.Failure.noClientID) {
            try SlackOAuthSession(
                clientID: "   ",
                supportDirectory: FileManager.default.temporaryDirectory
            )
        }
    }

    // MARK: - Which id Connect uses

    /// The precedence rule the app and `doctor` both render. It lives in the kit precisely so
    /// these cases exist — in the app target nothing could assert on it (A3).
    @Test("a pasted id outranks the built-in one")
    func pastedOutranksBuiltIn() {
        #expect(
            SlackOAuth.resolveClientID(override: "111.222", builtIn: "999.888")
                == .pasted("111.222")
        )
    }

    @Test("a blank override falls through to the built-in id")
    func blankOverrideFallsThrough() {
        #expect(SlackOAuth
            .resolveClientID(override: nil, builtIn: "999.888") == .builtIn("999.888"))
        #expect(SlackOAuth.resolveClientID(override: "", builtIn: "999.888") == .builtIn("999.888"))
        #expect(
            SlackOAuth.resolveClientID(override: "   ", builtIn: "999.888")
                == .builtIn("999.888")
        )
    }

    @Test("nothing to authorise with is nil, never an empty id")
    func nothingResolvesToNil() {
        #expect(SlackOAuth.resolveClientID(override: nil, builtIn: "") == nil)
        #expect(SlackOAuth.resolveClientID(override: "  ", builtIn: "") == nil)
    }

    @Test("a pasted id is trimmed before it is used")
    func pastedIsTrimmed() {
        #expect(SlackOAuth
            .resolveClientID(override: " 111.222 ", builtIn: "") == .pasted("111.222"))
    }

    // MARK: - The stored override item

    /// The one migration this app has. The legacy shape is pinned as the verbatim JSON the
    /// pre-ADR-0012 build wrote (a `JSONEncoder` of its `Credentials` struct), not a paraphrase.
    @Test("a legacy credentials item yields its id and asks to be rewritten")
    func legacyItemMigrates() {
        let legacy = Data(#"{"clientID":"111.222","clientSecret":"retired-secret"}"#.utf8)
        let parsed = SlackOAuth.parseStoredClientID(legacy)
        #expect(parsed?.id == "111.222")
        #expect(parsed?.isLegacyShape == true)
    }

    @Test("a plain-string item is read back as-is")
    func plainItemReads() {
        let parsed = SlackOAuth.parseStoredClientID(Data("111.222".utf8))
        #expect(parsed?.id == "111.222")
        #expect(parsed?.isLegacyShape == false)
    }

    @Test("an empty item is nil, not an empty id")
    func emptyItemIsNil() {
        #expect(SlackOAuth.parseStoredClientID(Data()) == nil)
    }

    /// `0xFF` cannot begin a UTF-8 sequence. A lenient decode would turn this into "\u{FFFD}" and
    /// hand back a client id made of replacement characters — a value invented to fill a hole,
    /// which is the one thing `.claude/rules/no-silent-fallbacks.md` forbids outright.
    @Test("bytes that are not UTF-8 are nil, not a string of replacement characters")
    func invalidUTF8IsNil() {
        #expect(SlackOAuth.parseStoredClientID(Data([0xFF, 0xFE, 0xFF])) == nil)
    }
}

/// RFC 7636. The vector in appendix B is the one fixed point the whole exchange turns on: get the
/// challenge transform wrong and Slack rejects every single connect with `invalid_grant`.
@Suite("PKCE")
struct PKCETests {
    @Test("the RFC 7636 appendix-B vector")
    func rfcVector() {
        #expect(
            PKCE.challenge(forVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test("verifiers are 43 chars of the base64url alphabet and do not repeat")
    func verifierShape() {
        let pkce = PKCE()
        #expect(pkce.verifier.count == 43, "32 bytes, base64url, unpadded")
        // The literal 66-character set RFC 7636 names, not `CharacterSet.alphanumerics` — that
        // set is Unicode-wide, and a swapped encoder emitting, say, full-width digits would
        // still satisfy it.
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let offenders = pkce.verifier.filter { !alphabet.contains($0) }
        #expect(offenders.isEmpty, "characters outside base64url in \(pkce.verifier): \(offenders)")
        let many = Set((0 ..< 50).map { _ in PKCE().verifier })
        #expect(many.count == 50)
    }

    @Test("the challenge is derived, not copied")
    func challengeIsDerived() {
        let pkce = PKCE()
        #expect(pkce.challenge == PKCE.challenge(forVerifier: pkce.verifier))
        #expect(pkce.challenge != pkce.verifier)
        #expect(pkce.challenge.count == 43, "SHA-256 is 32 bytes, so base64url is 43 chars")
    }
}
