import Foundation

/// A Slack custom status: the emoji and the text beside your name.
///
/// The domain type both halves of the app speak — `SlackKit` encodes it onto the wire and
/// `StatusEngine` reasons about it — which is why it lives in the target that depends on nothing.
public struct UserStatus: Sendable, Equatable, Codable {
    /// Slack's shortcode form, colons included: `":movie_camera:"`. Slack rejects a bare glyph.
    public var emoji: String
    public var text: String

    public init(emoji: String, text: String) {
        self.emoji = emoji
        self.text = text
    }

    /// The empty status. Setting this is how Slack's API clears one — there is no delete call.
    public static let cleared = UserStatus(emoji: "", text: "")

    public var isCleared: Bool {
        emoji.isEmpty && text.isEmpty
    }
}
