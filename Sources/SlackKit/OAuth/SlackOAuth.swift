import Foundation
import Security

/// Slack's OAuth v2 flow, as much of it as can happen without a window.
///
/// OnAir asks for **user** scopes only. A bot token cannot change your status, and asking for one
/// anyway would put a second, more powerful credential on the machine for no purpose (ADR-0006).
public enum SlackOAuth {
    /// The app's own identity, which the user creates at api.slack.com and pastes in once.
    ///
    /// It is not shipped in the binary. A client secret compiled into a distributed app is
    /// extractable by anyone who downloads it, and an app that pretends otherwise has told its
    /// users something false about what protects their account (ADR-0005).
    public struct Credentials: Sendable, Equatable, Codable {
        public var clientID: String
        public var clientSecret: String

        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }

        public var isComplete: Bool {
            !clientID.trimmingCharacters(in: .whitespaces).isEmpty
                && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
        }
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
        state: String
    ) -> URL? {
        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "user_scope", value: userScopes.joined(separator: ",")),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    /// Trades the one-time code for a user token. The token is returned, never stored — storage
    /// is the app's `TokenStore` and the Keychain (invariant A4).
    public static func exchange(
        code: String,
        credentials: Credentials,
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
        request.httpBody = Data(formEncoded([
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
            ("code", code),
            // Slack requires the same redirect_uri in both steps when the app has more than one
            // registered, and rejects the exchange outright when they differ.
            ("redirect_uri", redirectURI),
        ]).utf8)

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

/// One authorisation attempt, from minting the certificate to holding the token.
///
/// The kit does everything except open the browser: `NSWorkspace` is AppKit, and a kit that
/// imports AppKit stops being testable and stops being reusable (invariant A2). So the caller
/// gets a URL and is expected to open it.
public struct SlackOAuthSession: Sendable {
    public let authorizationURL: URL
    public let redirectURI: String

    private let receiver: LoopbackReceiver
    private let credentials: SlackOAuth.Credentials
    private let state: String
    private let baseURL: URL
    private let session: URLSession

    public enum Failure: Error, Sendable, Equatable {
        case incompleteCredentials
        case badAuthorizationURL
    }

    public init(
        credentials: SlackOAuth.Credentials,
        supportDirectory: URL,
        port: UInt16 = SlackOAuth.defaultPort,
        baseURL: URL = SlackClient.productionAPI,
        session: URLSession = .shared
    ) throws {
        guard credentials.isComplete else { throw Failure.incompleteCredentials }
        let state = SlackOAuth.newState()
        let redirectURI = SlackOAuth.redirectURI(port: port)
        guard let url = SlackOAuth.authorizationURL(
            clientID: credentials.clientID,
            redirectURI: redirectURI,
            state: state
        ) else {
            throw Failure.badAuthorizationURL
        }

        self.credentials = credentials
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
            credentials: credentials,
            redirectURI: redirectURI,
            baseURL: baseURL,
            session: session
        )
    }
}
