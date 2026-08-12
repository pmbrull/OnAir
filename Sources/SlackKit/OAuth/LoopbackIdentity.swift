import Foundation
import Security

/// The TLS identity the OAuth callback listener presents.
///
/// **Why this exists at all.** Slack's own documentation is unambiguous — *"The `redirect_uri`
/// must use HTTPS… A Redirect URL must also use HTTPS"* — and it lists `http://` targets as
/// invalid. The loopback receiver therefore has to speak TLS, and a loopback server needs a
/// certificate for `localhost`. The alternative was bouncing the callback off a hosted HTTPS page,
/// which puts a live authorisation code in somebody else's access log; keeping it on the machine
/// is worth one browser warning (ADR-0005).
///
/// **Why a subprocess.** Apple ships no public API that mints an X.509 certificate;
/// `SecCertificateCreateWithData` wants DER that something else produced. Hand-rolling an ASN.1
/// writer to avoid one call to `/usr/bin/openssl` would be a lot of security-critical code to own.
/// Arguments go as an array and the SAN comes from a written config file, never through a shell
/// (`docs/profile.md`, forbidden #4).
public enum LoopbackIdentity {
    public enum Failure: Error, Sendable, Equatable {
        case toolMissing(String)
        case toolFailed(command: String, status: Int32, stderr: String)
        case importFailed(OSStatus)
        case noIdentityInArchive
    }

    /// Not a secret, and deliberately so. It protects a key whose only job is to authenticate
    /// `localhost` to this machine's own browser for the seconds an OAuth callback is in flight.
    /// Treating it as a credential — Keychain item, generated value — would imply the key is worth
    /// something off this machine, and it is not.
    private static let archivePassphrase = "onair-loopback"
    private static let opensslPath = "/usr/bin/openssl"

    /// Returns the stored identity, minting one on first use. `directory` is created if absent.
    public static func loadOrCreate(in directory: URL) throws -> SecIdentity {
        let archive = directory.appendingPathComponent("loopback.p12")
        if FileManager.default.fileExists(atPath: archive.path) {
            // A corrupt or unreadable archive is recoverable by minting a new one; a stale
            // identity is worth less than a working connect button.
            if let identity = try? importIdentity(from: archive) {
                return identity
            }
            try? FileManager.default.removeItem(at: archive)
        }
        try mint(into: archive, workingIn: directory)
        return try importIdentity(from: archive)
    }

    // MARK: - Minting

    private static func mint(into archive: URL, workingIn directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard FileManager.default.isExecutableFile(atPath: opensslPath) else {
            throw Failure.toolMissing(opensslPath)
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onair-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let config = scratch.appendingPathComponent("openssl.cnf")
        let key = scratch.appendingPathComponent("key.pem")
        let certificate = scratch.appendingPathComponent("cert.pem")
        try configuration.write(to: config, atomically: true, encoding: .utf8)

        // LibreSSL — which is what /usr/bin/openssl is on macOS — did not carry `-addext` in
        // every shipped version, so the SAN goes through a config file, which every version reads.
        try run([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
            "-keyout", key.path, "-out", certificate.path, "-config", config.path,
        ])
        try run([
            "pkcs12", "-export", "-out", archive.path,
            "-inkey", key.path, "-in", certificate.path,
            "-name", "OnAir loopback", "-passout", "pass:\(archivePassphrase)",
        ])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archive.path
        )
    }

    /// A certificate with no SAN is rejected outright by every current browser — the CN fallback
    /// has been gone for years — so the SAN is the load-bearing part of this file, not decoration.
    private static let configuration = """
    [req]
    distinguished_name = dn
    x509_extensions = v3
    prompt = no
    [dn]
    CN = localhost
    O = OnAir
    [v3]
    subjectAltName = DNS:localhost, IP:127.0.0.1, IP:0:0:0:0:0:0:0:1
    basicConstraints = critical, CA:FALSE
    keyUsage = critical, digitalSignature, keyEncipherment
    extendedKeyUsage = serverAuth
    """

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        // Read before waiting: a subcommand that fills the 64KB pipe buffer would block forever
        // against a `waitUntilExit` that is itself waiting for the process to end.
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.toolFailed(
                command: "openssl \(arguments.first ?? "")",
                status: process.terminationStatus,
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
    }

    // MARK: - Importing

    private static func importIdentity(from archive: URL) throws -> SecIdentity {
        let data = try Data(contentsOf: archive)
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: archivePassphrase] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess else { throw Failure.importFailed(status) }
        guard let entries = items as? [[String: Any]],
              let identity = entries.first?[kSecImportItemIdentity as String]
        else {
            throw Failure.noIdentityInArchive
        }
        // The cast is unconditional because `kSecImportItemIdentity` is documented to hold a
        // SecIdentity; a CFTypeRef check here would only convert a framework contract break into
        // a silent nil.
        return identity as! SecIdentity // swiftlint:disable:this force_cast
    }
}
