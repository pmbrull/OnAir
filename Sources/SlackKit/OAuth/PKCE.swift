import CryptoKit
import Foundation
import Security

/// RFC 7636, the two halves of it OnAir needs.
///
/// PKCE is what lets a **public client** — an app that ships no secret, because a secret inside a
/// distributed binary is extractable by anyone — use the authorization-code flow safely. The
/// verifier never leaves this process until the exchange, so an attacker who intercepts the code
/// at the redirect holds nothing Slack will accept (ADR-0012).
public struct PKCE: Sendable, Equatable {
    /// 43 characters of base64url — 32 bytes from the system CSPRNG, the RFC's minimum length and
    /// its full recommended entropy.
    public let verifier: String
    /// base64url(SHA256(verifier)), sent on the authorize URL as `code_challenge`.
    public let challenge: String

    public static let method = "S256"

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Same stance as the state parameter: a CSPRNG failure papered over with a weaker
            // source would leave the flow looking protected while it was not.
            fatalError("SecRandomCopyBytes failed; refusing to generate a guessable PKCE verifier")
        }
        verifier = Self.base64URL(Data(bytes))
        challenge = Self.challenge(forVerifier: verifier)
    }

    /// Split out so the RFC 7636 appendix-B test vector can pin the transform itself.
    static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url without padding (RFC 4648 §5), which is the alphabet RFC 7636 mandates —
    /// standard base64's `+`, `/` and `=` are all rejected.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
