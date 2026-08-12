import Foundation
import Security
import SlackKit

/// The only door to the Keychain in this app (invariant A4, ADR-0006).
///
/// Two items, both generic passwords under the bundle identifier: the Slack app's client
/// credentials, and the user token they bought. Neither ever reaches `UserDefaults`, a log line,
/// or an error string — `scripts/check-architecture.sh` fails the build over all three.
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
        return String(decoding: data, as: UTF8.self)
    }

    static func saveToken(_ token: String) throws {
        try write(Data(token.utf8), account: Account.token)
    }

    static func deleteToken() {
        delete(account: Account.token)
    }

    // MARK: - The app's own credentials

    static func credentials() -> SlackOAuth.Credentials? {
        guard let data = read(account: Account.credentials) else { return nil }
        return try? JSONDecoder().decode(SlackOAuth.Credentials.self, from: data)
    }

    static func saveCredentials(_ credentials: SlackOAuth.Credentials) throws {
        try write(JSONEncoder().encode(credentials), account: Account.credentials)
    }

    static func deleteCredentials() {
        delete(account: Account.credentials)
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
