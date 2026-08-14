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

    /// The emoji as a person reads it: the glyph when the shortcode is one OnAir knows, and the
    /// shortcode verbatim when it is not — a workspace custom emoji resolves nowhere but Slack
    /// (ADR-0014).
    public var displayEmoji: String {
        EmojiShortcode.glyph(for: emoji) ?? emoji
    }

    /// "🎧 In a meeting" — the whole status on one line, for the menu, Settings and `doctor`.
    /// Either half may be empty, and an empty half must not leave a stray space behind it.
    public var display: String {
        [displayEmoji, text]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
