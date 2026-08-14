import Foundation
import StatusKit

/// The six Slack calls OnAir makes, and nothing else: the profile read and write, `auth.test`,
/// and the three DND calls (ADR-0013).
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

    public func currentStatus() async throws -> LiveStatus {
        let (data, status, retryAfter) = try await post("users.profile.get", body: nil)
        return try SlackWire.status(data, status: status, retryAfter: retryAfter)
    }

    /// `expiresAt` is Slack's `status_expiration`, and `0` — never expires — is right for every
    /// status OnAir chooses (ADR-0009). Only a restore passes one, and only the one the previous
    /// status already carried (ADR-0015).
    public func setStatus(_ status: UserStatus, expiresAt: Int = 0) async throws {
        let body = try SlackWire.profileSetBody(status, expiresAt: expiresAt)
        let (data, code, retryAfter) = try await post("users.profile.set", body: body)
        _ = try SlackWire.envelope(data, status: code, retryAfter: retryAfter)
    }

    // MARK: - Notifications (ADR-0013)

    public func snoozeState() async throws -> SnoozeState {
        let (data, code, retryAfter) = try await post("dnd.info", body: nil)
        return try SlackWire.snoozeState(data, status: code, retryAfter: retryAfter)
    }

    /// Returns the state Slack reports back — its `snooze_endtime` is the fingerprint the
    /// ownership rule compares against later (ADR-0013).
    public func setSnooze(minutes: Int) async throws -> SnoozeState {
        let (data, code, retryAfter) = try await post(
            "dnd.setSnooze",
            form: [("num_minutes", String(minutes))]
        )
        return try SlackWire.snoozeState(data, status: code, retryAfter: retryAfter)
    }

    public func endSnooze() async throws {
        let (data, code, retryAfter) = try await post("dnd.endSnooze", body: nil)
        do {
            _ = try SlackWire.envelope(data, status: code, retryAfter: retryAfter)
        } catch SlackError.api(code: "snooze_not_active") {
            // The goal state, arrived at without us — the slice expired between the decision and
            // the call. Not a failure.
        }
    }

    private func post(
        _ method: String,
        form: [(String, String)]
    ) async throws -> (Data, Int, String?) {
        try await post(method, body: Data(SlackOAuth.formEncoded(form).utf8), contentType: .form)
    }

    private enum BodyType { case json, form }

    private func post(
        _ method: String,
        body: Data?,
        contentType: BodyType = .json
    ) async throws -> (Data, Int, String?) {
        var request = URLRequest(url: baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Bodiless calls still declare the form type: Slack answers `invalid_content_type` to a
        // bare POST with none.
        if contentType == .json, body != nil {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else {
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
        }
        request.httpBody = body

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
