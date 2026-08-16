import Foundation
@testable import SlackKit
import Testing

/// The OAuth callback path, end to end and for real: a listener bound to loopback, and `URLSession`
/// playing the browser that the relay page sent here.
///
/// This is the one part of OnAir that a fixture genuinely cannot test. The failure modes here are a
/// port that will not bind, a request split across TCP segments, and a browser that asks for
/// something other than the callback — none of which a hand-written string can reproduce.
///
/// It used to mint a certificate with `/usr/bin/openssl` and speak TLS, because Slack redirected
/// straight here and refuses an `http://` redirect URL. Since ADR-0019 Slack redirects to
/// `https://onair.pmbrull.me/callback/` instead, and the hop from there to this listener is a
/// top-level navigation the browser makes in the clear. What that page does with a callback is
/// covered by invariant A7 rather than from here — it runs in a browser, not in this process.
///
/// Serialised, and one port per test: Swift Testing runs tests in parallel by default, and two
/// listeners racing for the same port would fail for a reason that has nothing to do with the code.
@Suite("Loopback receiver", .serialized)
struct LoopbackTests {
    @Test("a callback yields the code and answers the browser")
    func happyPath() async throws {
        let context = Context(port: 51301)
        defer { context.cleanUp() }

        let awaited = Task { try await context.receiver.waitForCallback(
            expectedState: "state-abc", timeout: 20
        ) }
        let (body, response) = try await context.get("/callback?code=code-xyz&state=state-abc")
        #expect(response.statusCode == 200)
        let page = try #require(String(bytes: body, encoding: .utf8))
        #expect(page.contains("OnAir is connected"))

        let callback = try await awaited.value
        #expect(callback.code == "code-xyz")
        #expect(callback.state == "state-abc")
    }

    /// Slack's own instruction: a state that does not come back unchanged means treat the
    /// authorisation as a forgery. The code must not be exchanged.
    ///
    /// This matters more since ADR-0019, not less: the listener now speaks plain HTTP, so `state`
    /// and the loopback-only binding are the whole of what stops a page the user happens to have
    /// open from planting a code here.
    @Test("a forged state is rejected")
    func forgedState() async throws {
        let context = Context(port: 51302)
        defer { context.cleanUp() }

        let awaited = Task { try await context.receiver.waitForCallback(
            expectedState: "the-real-state", timeout: 20
        ) }
        let (_, response) = try await context.get("/callback?code=code-xyz&state=forged")
        #expect(response.statusCode == 400)

        await #expect(throws: LoopbackReceiver.Failure.stateMismatch) {
            _ = try await awaited.value
        }
    }

    /// Browsers speculatively fetch /favicon.ico. Losing a login to that would be absurd, and it
    /// is exactly what a listener that ends on the first request it cannot parse would do.
    @Test("an unrelated request does not end the wait")
    func faviconDoesNotEndTheWait() async throws {
        let context = Context(port: 51303)
        defer { context.cleanUp() }

        let awaited = Task { try await context.receiver.waitForCallback(
            expectedState: "abc", timeout: 20
        ) }
        let (_, favicon) = try await context.get("/favicon.ico")
        #expect(favicon.statusCode == 404)

        let (_, callback) = try await context.get("/callback?code=still-works&state=abc")
        #expect(callback.statusCode == 200)
        #expect(try await awaited.value.code == "still-works")
    }

    /// The relay forwards `error` rather than swallowing it, so the app hears "declined" instead of
    /// sitting through the full five-minute timeout with the browser already closed.
    @Test("Slack refusing the app surfaces as a decline, not a hang")
    func userPressedCancel() async throws {
        let context = Context(port: 51304)
        defer { context.cleanUp() }

        let awaited = Task { try await context.receiver.waitForCallback(
            expectedState: "abc", timeout: 20
        ) }
        _ = try await context.get("/callback?error=access_denied&state=abc")

        await #expect(throws: LoopbackReceiver.Failure.declined("access_denied")) {
            _ = try await awaited.value
        }
    }

    @Test("a callback with no code is not mistaken for one")
    func incompleteCallback() async throws {
        let context = Context(port: 51306)
        defer { context.cleanUp() }

        let awaited = Task { try await context.receiver.waitForCallback(
            expectedState: "abc", timeout: 20
        ) }
        let (_, response) = try await context.get("/callback?state=abc")
        #expect(response.statusCode == 400)

        await #expect(throws: LoopbackReceiver.Failure.malformedRequest) {
            _ = try await awaited.value
        }
    }

    @Test("the wait gives up rather than holding the port forever")
    func timeout() async throws {
        let context = Context(port: 51305)
        defer { context.cleanUp() }

        await #expect(throws: LoopbackReceiver.Failure.timedOut) {
            _ = try await context.receiver.waitForCallback(expectedState: "abc", timeout: 0.5)
        }
    }

    // MARK: - Harness

    /// One receiver and a `URLSession` that will speak to it. No trust delegate any more: there is
    /// no certificate to accept, which is the point of ADR-0019.
    private struct Context {
        let receiver: LoopbackReceiver
        let session: URLSession
        let port: UInt16

        init(port: UInt16) {
            self.port = port
            receiver = LoopbackReceiver(port: port)
            session = URLSession(configuration: .ephemeral)
        }

        /// Retries until the listener has bound. `NWListener.start` is asynchronous, so the first
        /// connection attempt routinely lands before the socket exists.
        func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
            var lastError: (any Error)?
            for _ in 0 ..< 40 {
                do {
                    let (data, response) = try await session.data(from: url)
                    return try (data, #require(response as? HTTPURLResponse))
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            throw lastError ?? URLError(.cannotConnectToHost)
        }

        func cleanUp() {
            session.invalidateAndCancel()
        }
    }
}

/// These sentences are the only thing a user ever sees when a connection fails, so the risk worth
/// testing is a case whose text drops the one detail that makes it actionable — the port that was
/// taken, the reason Slack gave — leaving a message that is true and useless.
@Suite("Loopback failure text")
struct LoopbackFailureTextTests {
    @Test("every receiver failure says something, and carries its detail")
    func receiverFailures() {
        let cases: [LoopbackReceiver.Failure] = [
            .portUnavailable(51301),
            .listenerFailed("posix(EADDRINUSE)"),
            .timedOut,
            .declined("access_denied"),
            .stateMismatch,
            .malformedRequest,
        ]
        for failure in cases {
            #expect(!failure.summary.isEmpty, "\(failure) has no text")
        }
        #expect(LoopbackReceiver.Failure.portUnavailable(51301).summary.contains("51301"))
        #expect(LoopbackReceiver.Failure.declined("access_denied").summary
            .contains("access_denied"))
        #expect(
            LoopbackReceiver.Failure.listenerFailed("posix(EADDRINUSE)").summary
                .contains("posix(EADDRINUSE)")
        )
    }
}
