import Foundation
import Security
import SlackKit

/// The only door to the Keychain in this app (invariant A4, ADR-0006).
///
/// Two items, both generic passwords under the bundle identifier: the user token, and a client id
/// override when the user brings their own Slack app. The client id is not a secret (ADR-0012),
/// but it stays here rather than `UserDefaults` so there is exactly one storage story and the
/// architecture check keeps one boundary to police. Nothing here ever reaches a log line or an
/// error string — `scripts/check-architecture.sh` fails the build over it.
enum TokenStore {
    static let service = "io.umamidata.onair"

    private enum Account {
        static let token = "slack-token"
        static let credentials = "slack-client"
    }

    enum Failure: Error {
        case keychain(OSStatus)
    }

    // MARK: - The user token

    static func token() -> String? {
        guard let data = read(account: Account.token) else { return nil }
        // Failable rather than `String(decoding:)`: bytes that are not UTF-8 are not a token, and
        // substituting U+FFFD would hand Slack a plausible-looking string whose only possible
        // outcome is an authentication failure nothing on screen explains. `nil` reads as "no
        // token", which is the state that sends the user to Connect.
        return String(bytes: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) throws {
        try write(Data(token.utf8), account: Account.token)
    }

    static func deleteToken() {
        delete(account: Account.token)
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
