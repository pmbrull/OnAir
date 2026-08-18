import Foundation
import Security

/// Slack's OAuth v2 flow with PKCE, as much of it as can happen without a window.
///
/// OnAir is a **public client** (ADR-0012): it ships a `client_id` — public by design, visible in
/// every authorize URL — and no secret of any kind. PKCE is what makes that safe: the exchange
/// proves possession of the in-process verifier instead of a secret, so an intercepted code is
/// worthless. Slack's own instruction for this flow: "the client should not include
/// `client_secret` in the parameters."
///
/// It asks for **user** scopes only. A bot token cannot change your status, and asking for one
/// anyway would put a second, more powerful credential on the machine for no purpose (ADR-0006).
public enum SlackOAuth {
    /// The shared OnAir Slack app, created once by the maintainer with PKCE enabled. Empty until
    /// that app exists — and while it is, Settings shows a single Client ID field so the app is
    /// fully usable with an id of your own (GAP-0002 tracks the live verification).
    ///
    /// This is the one line to edit when the shared app is registered. A source constant rather
    /// than a build flag: there is nothing secret about it, and a value that ships in the binary
    /// should be findable in the repo.
    public static let builtInClientID = "10227089686096.11799764021207"

    /// Which client id Connect would use, with its provenance — the app and `doctor` both render
    /// this, so there is exactly one copy of the precedence rule and it is testable (A3).
    public enum ClientIDSource: Sendable, Equatable {
        /// The id of the user's own Slack app, pasted in Settings. Outranks the built-in one —
        /// pasting an id is the escape hatch for a workspace that blocks the shared app, and it
        /// keeps working after an upgrade ships a built-in id (ADR-0012).
        case pasted(String)
        case builtIn(String)

        public var id: String {
            switch self {
            case let .pasted(id), let .builtIn(id): id
            }
        }
    }

    /// `nil` — never an empty string — when there is nothing to authorise with, so no caller can
    /// mistake an unconfigured app for one with an empty id.
    public static func resolveClientID(
        override: String?,
        builtIn: String = SlackOAuth.builtInClientID
    ) -> ClientIDSource? {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return .pasted(trimmed)
            }
        }
        return builtIn.isEmpty ? nil : .builtIn(builtIn)
    }

    /// Decodes the stored client-id override item. Current builds write a plain UTF-8 string;
    /// builds before ADR-0012 wrote a JSON pair `{clientID, clientSecret}`. Pure, so the one
    /// migration this app has is pinned by tests instead of waiting for an upgrader to find out.
    ///
    /// `isLegacyShape` tells the caller to rewrite the item — the retired secret must not linger
    /// in anyone's Keychain. The secret itself is deliberately never decoded: `Decodable` ignores
    /// unknown keys, so the old shape is recognised without ever materialising the secret's bytes.
    public static func parseStoredClientID(_ data: Data) -> (id: String, isLegacyShape: Bool)? {
        struct LegacyItem: Decodable {
            let clientID: String
        }
        if let legacy = try? JSONDecoder().decode(LegacyItem.self, from: data) {
            return (legacy.clientID, true)
        }
        // Bytes that are not UTF-8 are not a client id, and join the empty case in reporting
        // "nothing usable stored here" rather than a string built out of replacement characters.
        guard let plain = String(bytes: data, encoding: .utf8), !plain.isEmpty else { return nil }
        return (plain, false)
    }

    /// Both pairs follow the same rule: `read` as well as `write`, because OnAir must see what is
    /// there before it may touch it — the status to decide overwrite-and-restore (ADR-0008), the
    /// snooze to tell the user's from its own (ADR-0013). This list is what a token is actually
    /// granted; the manifest in the README merely permits it, and the two must agree or
    /// reconnecting can never cure a missing_scope.
    public static let userScopes = [
        "users.profile:read", "users.profile:write",
        "dnd:read", "dnd:write",
    ]

    /// Fixed, because the relay page hands the callback to exactly this port. The page ships from
    /// this repository for that reason, and `.github/workflows/pages.yml` refuses to deploy one
    /// that disagrees with this line.
    public static let defaultPort: UInt16 = 51234

    /// The Redirect URL registered in the Slack app — a page on the public internet, not this
    /// machine. It forwards `code` and `state` to `defaultPort` on the loopback, which is what lets
    /// the listener speak plain HTTP and the browser show no warning (ADR-0019).
    ///
    /// The trailing slash is load-bearing twice over: it is the path GitHub Pages actually serves
    /// (the unslashed form is a 301), and Slack compares this string byte for byte against the
    /// registration — at authorize *and* again at the exchange.
    public static let redirectURI = "https://onair.pmbrull.me/callback/"

    /// 256 bits from the system CSPRNG. This is the only thing standing between the listener and a
    /// code planted by a page the user happens to have open, so it is not `UUID()`.
    public static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // The system CSPRNG failing is not a case to paper over with `Int.random`, which would
            // leave the flow looking protected while it was not.
            fatalError("SecRandomCopyBytes failed; refusing to generate a guessable OAuth state")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        pkce: PKCE
    ) -> URL? {
        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "user_scope", value: userScopes.joined(separator: ",")),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.method),
        ]
        return components?.url
    }

    /// Trades the one-time code for a user credential, proving possession of the verifier instead
    /// of a secret. It is returned, never stored — storage is the app's `TokenStore` and the
    /// Keychain (invariant A4).
    public static func exchange(
        code: String,
        clientID: String,
        pkce: PKCE,
        redirectURI: String,
        baseURL: URL = SlackClient.productionAPI,
        session: URLSession = .shared
    ) async throws -> SlackCredential {
        try await postToAccess(
            exchangeBody(code: code, clientID: clientID, pkce: pkce, redirectURI: redirectURI),
            baseURL: baseURL,
            session: session
        )
    }

    /// Trades a refresh token for a fresh credential (ADR-0020).
    ///
    /// Same endpoint as the exchange, and still no secret: a public client renews by presenting the
    /// refresh token alone. PKCE plays no part here — the verifier proved the *authorisation*, and
    /// there is no browser in this call to intercept anything.
    ///
    /// Slack's refresh tokens are single-use, so the caller must persist what comes back before the
    /// old one is discarded, and must not run two of these at once.
    public static func renew(
        refreshToken: String,
        clientID: String,
        baseURL: URL = SlackClient.productionAPI,
        session: URLSession = .shared
    ) async throws -> SlackCredential {
        try await postToAccess(
            renewalBody(refreshToken: refreshToken, clientID: clientID),
            baseURL: baseURL,
            session: session
        )
    }

    private static func postToAccess(
        _ body: String,
        baseURL: URL,
        session: URLSession
    ) async throws -> SlackCredential {
        var request = URLRequest(url: baseURL.appendingPathComponent("oauth.v2.access"))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SlackError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SlackError.malformedResponse("not an HTTP response")
        }
        return try SlackWire.credential(
            data,
            status: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After")
        )
    }

    /// Split from `exchange` so a test can pin what the body contains — the verifier — and what
    /// it must never contain again: a `client_secret` (ADR-0012).
    static func exchangeBody(
        code: String,
        clientID: String,
        pkce: PKCE,
        redirectURI: String
    ) -> String {
        formEncoded([
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", pkce.verifier),
            // Slack requires the same redirect_uri in both steps when the app has more than one
            // registered, and rejects the exchange outright when they differ.
            ("redirect_uri", redirectURI),
        ])
    }

    /// Split from `renew` for the same reason `exchangeBody` is split from `exchange`: a test can
    /// pin that a renewal presents the refresh token and `grant_type`, and that it still sends no
    /// `client_secret` — the public-client property of ADR-0012 has to survive every new call, not
    /// just the one it was written about.
    ///
    /// No `redirect_uri`: there is no redirect in a renewal, and Slack compares that string byte
    /// for byte when it is present.
    static func renewalBody(refreshToken: String, clientID: String) -> String {
        formEncoded([
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    /// RFC 3986 unreserved only. `URLComponents` leaves `:` and `/` unescaped in a query, which is
    /// legal there but not in a form body — and `redirect_uri` is nothing but those two characters.
    static func formEncoded(_ pairs: [(String, String)]) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return pairs.map { name, value in
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
            let encodedValue = value
                .addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(encodedName)=\(encodedValue)"
        }.joined(separator: "&")
    }
}

/// One authorisation attempt, from opening the port to holding the token. The PKCE pair is
/// generated here and lives exactly as long as the attempt.
///
/// The kit does everything except open the browser: `NSWorkspace` is AppKit, and a kit that
/// imports AppKit stops being testable and stops being reusable (invariant A2). So the caller
/// gets a URL and is expected to open it.
public struct SlackOAuthSession: Sendable {
    public let authorizationURL: URL
    public let redirectURI: String

    private let receiver: LoopbackReceiver
    private let clientID: String
    private let pkce: PKCE
    private let state: String
    private let baseURL: URL
    private let session: URLSession

    public enum Failure: Error, Sendable, Equatable {
        case noClientID
        case badAuthorizationURL
    }

    public init(
        clientID: String,
        port: UInt16 = SlackOAuth.defaultPort,
        baseURL: URL = SlackClient.productionAPI,
        session: URLSession = .shared
    ) throws {
        let trimmed = clientID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Failure.noClientID }
        let state = SlackOAuth.newState()
        let pkce = PKCE()
        let redirectURI = SlackOAuth.redirectURI
        guard let url = SlackOAuth.authorizationURL(
            clientID: trimmed,
            redirectURI: redirectURI,
            state: state,
            pkce: pkce
        ) else {
            throw Failure.badAuthorizationURL
        }

        self.clientID = trimmed
        self.pkce = pkce
        self.state = state
        self.redirectURI = redirectURI
        self.baseURL = baseURL
        self.session = session
        authorizationURL = url
        receiver = LoopbackReceiver(port: port)
    }

    /// Waits for the browser, then exchanges the code. Five minutes is long enough to find the
    /// right workspace in the picker and short enough that a forgotten tab releases the port.
    public func awaitCredential(timeout: TimeInterval = 300) async throws -> SlackCredential {
        let callback = try await receiver.waitForCallback(expectedState: state, timeout: timeout)
        return try await SlackOAuth.exchange(
            code: callback.code,
            clientID: clientID,
            pkce: pkce,
            redirectURI: redirectURI,
            baseURL: baseURL,
            session: session
        )
    }
}
