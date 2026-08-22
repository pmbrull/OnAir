import Foundation
import StatusKit

/// Where the policy is kept between launches.
///
/// `UserDefaults`, as one JSON blob rather than a key per field: the policy is decoded as a whole
/// by `StatusPolicy`, which fills in anything a newer build added, so a scattered set of keys
/// would only invent a second place for them to disagree.
///
/// Static and free of the main actor on purpose, so `onair doctor` can read the same policy the
/// app runs without standing up the app.
enum PolicyStore {
    private static let key = "policy"

    static func load() -> StatusPolicy {
        guard let data = UserDefaults.standard.data(forKey: key) else { return .standard }
        // A policy that will not decode is replaced, not repaired: guessing which half of a
        // corrupt blob was meant is how a user ends up broadcasting a status they never chose.
        return (try? JSONDecoder().decode(StatusPolicy.self, from: data)) ?? .standard
    }

    static func save(_ policy: StatusPolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// OnAir's application-support directory. It held the loopback certificate until ADR-0019
    /// deleted it, and nothing writes here now — `make uninstall` still removes the directory
    /// because a machine that connected before the callback moved has a `loopback.p12` sitting in
    /// it.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OnAir", isDirectory: true)
    }
}
