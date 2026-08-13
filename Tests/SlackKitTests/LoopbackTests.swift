import Foundation
import Security
@testable import SlackKit
import Testing

/// The OAuth callback path, end to end and for real: a certificate minted by `/usr/bin/openssl`,
/// a TLS listener bound to loopback, and `URLSession` playing the browser.
///
/// This is the one part of OnAir that a fixture genuinely cannot test. The failure modes here are
/// a certificate the TLS stack rejects, a port that will not bind, and an HTTP request split
/// across segments — none of which a hand-written string can reproduce.
///
/// Serialised, and one port per test: Swift Testing runs tests in parallel by default, and two
/// listeners racing for the same port would fail for a reason that has nothing to do with the code.
@Suite("Loopback receiver", .serialized)
struct LoopbackTests {
    // MARK: - The certificate

    @Test("minting produces a localhost identity and keeps it")
    func identityIsMintedAndReused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try LoopbackIdentity.loadOrCreate(in: directory)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("loopback.p12").path
        ))
        #expect(try subjectSummary(of: first) == "localhost")

        // The second call must reuse the archive: minting per launch would make the browser warn
        // about a *different* certificate every time.
        let second = try LoopbackIdentity.loadOrCreate(in: directory)
        #expect(try certificateData(of: first) == certificateData(of: second))
    }

    @Test("a corrupt archive is replaced rather than fatal")
    func corruptArchiveIsReplaced() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("loopback.p12")
        try Data("not a pkcs12".utf8).write(to: archive)

        let identity = try LoopbackIdentity.loadOrCreate(in: directory)
        #expect(try subjectSummary(of: identity) == "localhost")
    }

    // MARK: - The callback

    @Test("a callback yields the code and answers the browser")
    func happyPath() async throws {
        let context = try Context(port: 51301)
        defer { context.cleanUp() }

        let awaited = Task { try await context.receiver.waitForCallback(
            expectedState: "state-abc", timeout: 20
        ) }
        let (body, response) = try await context.get("/callback?code=code-xyz&state=state-abc")
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("OnAir is connected"))

        let callback = try await awaited.value
        #expect(callback.code == "code-xyz")
        #expect(callback.state == "state-abc")
    }

    /// Slack's own instruction: a state that does not come back unchanged means treat the
    /// authorisation as a forgery. The code must not be exchanged.
    @Test("a forged state is rejected")
    func forgedState() async throws {
        let context = try Context(port: 51302)
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
        let context = try Context(port: 51303)
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

    @Test("Slack refusing the app surfaces as a decline, not a hang")
    func userPressedCancel() async throws {
        let context = try Context(port: 51304)
        defer { context.cleanUp() }

        let awaited = Task { try await context.receiver.waitForCallback(
            expectedState: "abc", timeout: 20
        ) }
        _ = try await context.get("/callback?error=access_denied&state=abc")

        await #expect(throws: LoopbackReceiver.Failure.declined("access_denied")) {
            _ = try await awaited.value
        }
    }

    @Test("the wait gives up rather than holding the port forever")
    func timeout() async throws {
        let context = try Context(port: 51305)
        defer { context.cleanUp() }

        await #expect(throws: LoopbackReceiver.Failure.timedOut) {
            _ = try await context.receiver.waitForCallback(expectedState: "abc", timeout: 0.5)
        }
    }

    // MARK: - Harness

    /// One receiver, one temporary certificate, and a `URLSession` that will speak to it.
    private struct Context {
        let receiver: LoopbackReceiver
        let session: URLSession
        let port: UInt16
        let directory: URL

        init(port: UInt16) throws {
            self.port = port
            directory = try makeDirectory()
            receiver = try LoopbackReceiver(
                port: port,
                identity: LoopbackIdentity.loadOrCreate(in: directory)
            )
            session = URLSession(
                configuration: .ephemeral,
                delegate: LoopbackTrust(),
                delegateQueue: nil
            )
        }

        /// Retries until the listener has bound. `NWListener.start` is asynchronous, so the first
        /// connection attempt routinely lands before the socket exists.
        func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(URL(string: "https://localhost:\(port)\(path)"))
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
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Accepts the self-signed certificate, and **only** on loopback. A blanket "trust everything"
    /// delegate in a test is a habit that eventually gets copied into shipping code.
    private final class LoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(
            _: URLSession,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace
                .authenticationMethod == NSURLAuthenticationMethodServerTrust,
                challenge.protectionSpace.host == "localhost",
                let trust = challenge.protectionSpace.serverTrust
            else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
    }
}

private func makeDirectory() throws -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("onair-tests-\(UUID().uuidString)", isDirectory: true)
}

private func certificateData(of identity: SecIdentity) throws -> Data {
    var certificate: SecCertificate?
    SecIdentityCopyCertificate(identity, &certificate)
    return try SecCertificateCopyData(#require(certificate)) as Data
}

private func subjectSummary(of identity: SecIdentity) throws -> String? {
    var certificate: SecCertificate?
    SecIdentityCopyCertificate(identity, &certificate)
    return try SecCertificateCopySubjectSummary(#require(certificate)) as String?
}
