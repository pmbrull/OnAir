import Foundation
import SlackKit

// The vocabulary `AppCoordinator` publishes and the views consume — kept beside it rather than
// inside it so the coordinator file stays about the coordinating.

/// The one place the Keychain override meets the kit's precedence rule. The rule itself lives in
/// `SlackOAuth.resolveClientID`, where it is tested (A3); this is only the join.
func resolvedClientID() -> SlackOAuth.ClientIDSource? {
    SlackOAuth.resolveClientID(override: TokenStore.clientIDOverride())
}

/// How OnAir stands with Slack right now.
enum ConnectionState: Equatable {
    /// No built-in client id in this build and none pasted — Connect has nothing to authorise
    /// against.
    case notConfigured
    /// A client id to authorise with, but no token: the user has not pressed Connect.
    case disconnected
    case connecting
    case connected(SlackIdentity)
    /// A token that Slack will not accept. Retrying will not help.
    case needsReconnect(String)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

/// One line in the menu's short history. The app's answer to "why is my status like this".
struct ActivityEntry: Identifiable, Equatable {
    enum Level: Equatable { case info, warning, failure }

    let id = UUID()
    let at: Date
    let level: Level
    let message: String
}
