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
        let plain = String(decoding: data, as: UTF8.self)
        return plain.isEmpty ? nil : (plain, false)
    }

    /// `read` is needed as well as `write`: OnAir has to see the status already there to decide
    /// whether it may replace it, and to know what to put back afterwards (ADR-0008).
    public static let userScopes = ["users.profile:read", "users.profile:write"]

    /// Fixed, because it has to match the Redirect URL registered in the Slack app. A port picked
    /// at random each launch could not be registered in advance.
    public static let defaultPort: UInt16 = 51234

    public static func redirectURI(port: UInt16 = defaultPort) -> String {
        "https://localhost:\(port)\(LoopbackReceiver.callbackPath)"
    }

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

    /// Trades the one-time code for a user token, proving possession of the verifier instead of a
    /// secret. The token is returned, never stored — storage is the app's `TokenStore` and the
    /// Keychain (invariant A4).
    public static func exchange(
        code: String,
        clientID: String,
        pkce: PKCE,
        redirectURI: String,
        baseURL: URL = SlackClient.productionAPI,
        session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("oauth.v2.access"))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data(
            exchangeBody(code: code, clientID: clientID, pkce: pkce, redirectURI: redirectURI).utf8
        )

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
        return try SlackWire.userAccessToken(
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

/// One authorisation attempt, from minting the certificate to holding the token. The PKCE pair is
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
        supportDirectory: URL,
        port: UInt16 = SlackOAuth.defaultPort,
        baseURL: URL = SlackClient.productionAPI,
        session: URLSession = .shared
    ) throws {
        let trimmed = clientID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Failure.noClientID }
        let state = SlackOAuth.newState()
        let pkce = PKCE()
        let redirectURI = SlackOAuth.redirectURI(port: port)
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
        receiver = try LoopbackReceiver(
            port: port,
            identity: LoopbackIdentity.loadOrCreate(in: supportDirectory)
        )
    }

    /// Waits for the browser, then exchanges the code. Five minutes is long enough to find the
    /// right workspace in the picker and short enough that a forgotten tab releases the port.
    public func awaitToken(timeout: TimeInterval = 300) async throws -> String {
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
