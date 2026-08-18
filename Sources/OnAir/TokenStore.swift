import Foundation
import Security
import SlackKit

/// The only door to the Keychain in this app (invariant A4, ADR-0006).
///
/// Three items, all generic passwords under the bundle identifier: the user token, its renewal
/// record (ADR-0020), and a client id override when the user brings their own Slack app. The
/// client id is not a secret (ADR-0012), but it stays here rather than `UserDefaults` so there is
/// exactly one storage story and the architecture check keeps one boundary to police. Nothing here
/// ever reaches a log line or an error string — `scripts/check-architecture.sh` fails the build
/// over it.
enum TokenStore {
    static let service = "io.umamidata.onair"

    private enum Account {
        static let token = "slack-token"
        static let renewal = "slack-renewal"
        static let credentials = "slack-client"
    }

    enum Failure: Error {
        case keychain(OSStatus)
    }

    // MARK: - The user credential

    /// A credential with no renewal record reads as non-expiring and non-renewable, which is
    /// exactly what a token stored by a build older than ADR-0020 is: it still works, and OnAir
    /// still has no way to renew it. An upgrade must not log anyone out.
    static func credential() -> SlackCredential? {
        guard let accessToken = storedAccessToken() else { return nil }
        guard case let .present(renewal) = renewalRecord() else {
            return SlackCredential(accessToken: accessToken)
        }
        return SlackCredential(
            accessToken: accessToken,
            expiresAt: renewal.expiresAt,
            refreshToken: renewal.refreshToken
        )
    }

    /// Kept apart from `credential()` so `doctor` can tell an absent record from a corrupt one.
    /// Both leave OnAir unable to renew; only one of them is a bug in this app
    /// (`.claude/rules/no-silent-fallbacks.md`).
    static func renewalRecord() -> SlackCredential.RenewalRecord {
        guard let data = read(account: Account.renewal) else { return .absent }
        return SlackCredential.decodeRenewal(data)
    }

    /// The renewal record is written **first**, and deliberately.
    ///
    /// Slack's refresh tokens are single-use. Crashing between these two writes with the access
    /// token saved and the refresh token lost breaks the chain and costs the user a reconnect;
    /// crashing the other way round leaves the previous access token — still valid, since renewal
    /// happens before expiry — beside a refresh token that works. One order loses the connection,
    /// the other loses nothing.
    static func saveCredential(_ credential: SlackCredential) throws {
        try write(SlackCredential.encode(credential.renewal), account: Account.renewal)
        try write(Data(credential.accessToken.utf8), account: Account.token)
    }

    static func deleteCredential() {
        delete(account: Account.token)
        delete(account: Account.renewal)
    }

    private static func storedAccessToken() -> String? {
        guard let data = read(account: Account.token) else { return nil }
        // Failable rather than `String(decoding:)`: bytes that are not UTF-8 are not a credential,
        // and substituting U+FFFD would hand Slack a plausible-looking string whose only possible
        // outcome is an authentication failure nothing on screen explains. `nil` reads as "nothing
        // stored", which is the state that sends the user to Connect.
        return String(bytes: data, encoding: .utf8)
    }

    // MARK: - The client id override

    /// The id of the user's own Slack app, when they use one instead of the built-in shared app.
    static func clientIDOverride() -> String? {
        guard let data = read(account: Account.credentials) else { return nil }
        return SlackOAuth.parseStoredClientID(data)?.id
    }

    static func saveClientIDOverride(_ clientID: String) throws {
        try write(Data(clientID.utf8), account: Account.credentials)
    }

    static func deleteClientIDOverride() {
        delete(account: Account.credentials)
    }

    /// Rewrites a pre-ADR-0012 item — a JSON pair carrying the retired client secret — down to the
    /// bare id. Run at every launch rather than lazily on read: the common upgrade path (token
    /// present, Settings never opened) would otherwise never touch the item, and the secret would
    /// linger in the Keychain under a README that promises it is gone.
    ///
    /// Returns `false` when a legacy item exists and could not be rewritten, so the caller can say
    /// so instead of the scrub failing silently (`.claude/rules/no-silent-fallbacks.md`); the next
    /// launch retries.
    static func scrubLegacyClientItem() -> Bool {
        guard let data = read(account: Account.credentials),
              let parsed = SlackOAuth.parseStoredClientID(data),
              parsed.isLegacyShape
        else { return true }
        do {
            try saveClientIDOverride(parsed.id)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Keychain

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Update-then-add rather than delete-then-add: deleting first leaves a window where a crash
    /// loses the token and the user has to reconnect for no reason.
    private static func write(_ data: Data, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = [kSecValueData as String: data] as CFDictionary
        let updated = SecItemUpdate(identity as CFDictionary, update)
        if updated == errSecSuccess {
            return
        }
        guard updated == errSecItemNotFound else { throw Failure.keychain(updated) }

        var insert = identity
        insert[kSecValueData as String] = data
        // Not `AfterFirstUnlock`: OnAir has nothing to do while the machine is locked, and the
        // weaker class would keep the token readable in more states than it is ever needed in.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(added) }
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
