import Foundation
import StatusKit

/// The three Slack calls OnAir makes, and nothing else.
///
/// The client is handed a token and **never persists one** — storage is the app's `TokenStore`
/// and the Keychain (invariant A4, ADR-0006). It is a value, so reconnecting means constructing a
/// new one rather than mutating a shared object out from under an in-flight request.
public struct SlackClient: Sendable {
    public static let productionAPI = URL(string: "https://slack.com/api/")!

    private let token: String
    private let baseURL: URL
    private let session: URLSession

    /// `baseURL` is injectable so a test can point the client at a local stub. It is not a user
    /// setting: a configurable API host on an app holding a Slack token is an exfiltration switch.
    public init(
        token: String,
        baseURL: URL = SlackClient.productionAPI,
        session: URLSession = .shared
    ) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
    }

    public func identity() async throws -> SlackIdentity {
        let (data, status, retryAfter) = try await post("auth.test", body: nil)
        return try SlackWire.identity(data, status: status, retryAfter: retryAfter)
    }

    public func currentStatus() async throws -> UserStatus {
        let (data, status, retryAfter) = try await post("users.profile.get", body: nil)
        return try SlackWire.status(data, status: status, retryAfter: retryAfter)
    }

    public func setStatus(_ status: UserStatus) async throws {
        let body = try SlackWire.profileSetBody(status)
        let (data, code, retryAfter) = try await post("users.profile.set", body: body)
        _ = try SlackWire.envelope(data, status: code, retryAfter: retryAfter)
    }

    private func post(_ method: String, body: Data?) async throws -> (Data, Int, String?) {
        var request = URLRequest(url: baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else {
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // `localizedDescription` of a URLError never contains the request headers, so this
            // cannot leak the bearer token (A4).
            throw SlackError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SlackError.malformedResponse("not an HTTP response")
        }
        return (data, http.statusCode, http.value(forHTTPHeaderField: "Retry-After"))
    }
}
