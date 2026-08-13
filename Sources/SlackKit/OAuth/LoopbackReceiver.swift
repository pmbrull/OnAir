import Foundation
import Network
import Security

/// A one-shot HTTPS server on `localhost` that catches Slack's OAuth redirect.
///
/// It accepts exactly one authorisation and then stops. TLS is not optional here — Slack refuses
/// to register an `http://` redirect URL at all (ADR-0005) — so the listener presents the identity
/// from `LoopbackIdentity`, and the browser shows its self-signed warning once.
///
/// Concurrency: every mutable field is confined to `queue`, and `NWListener`/`NWConnection` deliver
/// their callbacks on it because they were started with it.
public final class LoopbackReceiver: @unchecked Sendable {
    public struct Callback: Sendable, Equatable {
        public let code: String
        public let state: String
    }

    public enum Failure: Error, Sendable, Equatable {
        case identityUnusable
        case portUnavailable(UInt16)
        case listenerFailed(String)
        case timedOut
        /// Slack redirected with `?error=…`; almost always the user pressing Cancel.
        case declined(String)
        /// The `state` did not come back as it was sent. Treated as a forgery, per Slack's own
        /// guidance, and the code is discarded unexchanged.
        case stateMismatch
        case malformedRequest
    }

    public static let callbackPath = "/callback"

    private let queue = DispatchQueue(label: "io.umamidata.onair.loopback")
    private let port: UInt16
    private let identity: SecIdentity

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<Callback, any Error>?
    private var expectedState = ""
    private var settled = false

    public init(port: UInt16, identity: SecIdentity) {
        self.port = port
        self.identity = identity
    }

    deinit { listener?.cancel() }

    /// Binds, waits for one callback, and tears everything down before returning. Cancelling the
    /// surrounding task closes the port.
    public func waitForCallback(
        expectedState: String,
        timeout: TimeInterval
    ) async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    // Cancellation can win the race to this queue: `onCancel` runs as soon as the
                    // surrounding task is cancelled, which may be before the continuation has been
                    // stored. Without this guard `finish` has already marked the receiver settled,
                    // so nothing would ever resume and the await would hang forever.
                    guard !self.settled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    self.expectedState = expectedState
                    do {
                        try self.startListening()
                    } catch {
                        self.finish(.failure(error))
                        return
                    }
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        self.finish(.failure(Failure.timedOut))
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    // MARK: - Listening

    private func startListening() throws {
        guard let secIdentity = sec_identity_create(identity) else {
            throw Failure.identityUnusable
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        // Nothing off this machine may reach the port the authorisation code arrives on.
        parameters.requiredInterfaceType = .loopback
        // A previous attempt that ended in TIME_WAIT should not make Connect fail for a minute.
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw Failure.portUnavailable(port)
        }
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case let .failed(error) = state else { return }
            if case let .posix(code) = error, code == .EADDRINUSE {
                finish(.failure(Failure.portUnavailable(port)))
            } else {
                finish(.failure(Failure.listenerFailed(String(describing: error))))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    /// An HTTP request head can be split across TCP segments, so read until the blank line rather
    /// than assuming one `receive` holds the whole thing.
    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let chunk {
                buffer.append(chunk)
            }
            if error != nil {
                connection.cancel()
                return
            }
            if let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                handleRequest(buffer[..<separator.lowerBound], on: connection)
                return
            }
            // 64KB of request head with no blank line is not a browser.
            if isComplete || buffer.count > 64 * 1024 {
                reply(on: connection, status: "400 Bad Request", html: Self.page(
                    title: "That didn't look like Slack",
                    detail: "OnAir could not read the request. Try Connect again."
                ), then: .failure(Failure.malformedRequest))
                return
            }
            receive(on: connection, accumulated: buffer)
        }
    }

    private func handleRequest(_ head: Data, on connection: NWConnection) {
        let text = String(decoding: head, as: UTF8.self)
        guard let requestLine = text.split(separator: "\r\n", omittingEmptySubsequences: false)
            .first,
            let target = requestLine.split(separator: " ").dropFirst().first,
            let components = URLComponents(string: "http://localhost\(target)")
        else {
            reply(on: connection, status: "400 Bad Request", html: Self.page(
                title: "That didn't look like Slack",
                detail: "OnAir could not read the request. Try Connect again."
            ), then: .failure(Failure.malformedRequest))
            return
        }

        // Browsers speculatively fetch /favicon.ico against the same origin. Failing the whole
        // authorisation because Safari wanted an icon would be an absurd way to lose a login.
        guard components.path == Self.callbackPath else {
            reply(on: connection, status: "404 Not Found", html: "", then: nil)
            return
        }

        let items = components.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        if let refusal = value("error") {
            reply(on: connection, status: "200 OK", html: Self.page(
                title: "Not connected",
                detail: "Slack reported: \(refusal). Nothing was changed."
            ), then: .failure(Failure.declined(refusal)))
            return
        }
        guard let code = value("code"), let state = value("state") else {
            reply(on: connection, status: "400 Bad Request", html: Self.page(
                title: "Incomplete callback",
                detail: "Slack's redirect carried no authorisation code."
            ), then: .failure(Failure.malformedRequest))
            return
        }
        guard state == expectedState else {
            // Slack's own instruction: a state that does not match means treat the authorisation
            // as a forgery. The code is thrown away rather than exchanged.
            reply(on: connection, status: "400 Bad Request", html: Self.page(
                title: "Rejected",
                detail: "The callback did not match the request OnAir made. Nothing was changed."
            ), then: .failure(Failure.stateMismatch))
            return
        }
        reply(on: connection, status: "200 OK", html: Self.page(
            title: "OnAir is connected",
            detail: "You can close this tab and go back to the menu bar."
        ), then: .success(Callback(code: code, state: state)))
    }

    // MARK: - Replying

    /// `then: nil` answers the request without ending the wait — used for the requests a browser
    /// makes that are not the callback.
    private func reply(
        on connection: NWConnection,
        status: String,
        html: String,
        then result: Result<Callback, any Error>?
    ) {
        let body = Data(html.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
            // Resolve only after the bytes are away: tearing the listener down first can drop the
            // response, leaving the user staring at a browser error after a successful login.
            guard let result else { return }
            self.queue.async { self.finish(result) }
        })
    }

    private func finish(_ result: Result<Callback, any Error>) {
        guard !settled else { return }
        settled = true
        listener?.cancel()
        listener = nil
        for connection in connections {
            connection.cancel()
        }
        connections = []
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    private static func page(title: String, detail: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>OnAir</title>
        <style>
        body{font:16px -apple-system,system-ui,sans-serif;margin:0;height:100vh;display:flex;
        align-items:center;justify-content:center;background:#f6f6f7;color:#1d1d1f}
        main{text-align:center;max-width:32rem;padding:2rem}
        h1{font-size:1.25rem;margin:0 0 .5rem}p{margin:0;color:#6e6e73}
        </style></head><body><main><h1>\(escaped(
            title
        ))</h1><p>\(escaped(detail))</p></main></body></html>
        """
    }

    /// The refusal reason on this page comes out of a URL anyone can construct and aim at the
    /// listener. It is plain text as far as OnAir is concerned, so it is escaped rather than
    /// trusted — script running on a page served from `https://localhost` is not something to
    /// hand out for free.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
