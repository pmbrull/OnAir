import Foundation
@testable import StatusKit
import Testing

/// The table is generated data, so what is worth testing is not "does 🎧 exist" but "did the pack
/// survive the parse" — one dropped token shifts every pair after it and every lookup silently
/// returns the wrong glyph.
@Suite("Emoji shortcodes")
struct EmojiShortcodeTests {
    @Test("the shortcode from the screenshot renders")
    func headphones() {
        #expect(EmojiShortcode.glyph(for: ":headphones:") == "🎧")
        #expect(EmojiShortcode.glyph(for: "headphones") == "🎧", "colons are optional")
        #expect(EmojiShortcode.glyph(for: " :headphones: ") == "🎧")
    }

    @Test("every shortcode Settings offers as a preset resolves")
    func presetsResolve() {
        for shortcode in [
            ":movie_camera:", ":headphones:", ":red_circle:", ":speech_balloon:",
        ] {
            #expect(EmojiShortcode.glyph(for: shortcode) != nil, "\(shortcode) did not resolve")
        }
    }

    /// The lookup is lenient about the colons so a Settings field can render mid-keystroke; Slack
    /// is not, and it fails by silently keeping the old emoji. Something has to be able to tell
    /// "renders fine" from "Slack will accept it" apart, or the preview becomes a false all-clear.
    @Test("the wire shape is stricter than the lookup")
    func wireShape() {
        #expect(EmojiShortcode.glyph(for: "headphones") != nil)
        #expect(!EmojiShortcode.isWireShaped("headphones"))
        #expect(EmojiShortcode.isWireShaped(":headphones:"))
        #expect(EmojiShortcode.isWireShaped(" :collate: "), "unknown but well-formed is still wire")
        #expect(!EmojiShortcode.isWireShaped(":headphones"))
        #expect(!EmojiShortcode.isWireShaped(""))
        #expect(!EmojiShortcode.isWireShaped("::"), "the empty shortcode is not a shortcode")
    }

    /// A workspace custom emoji lives in one Slack workspace and resolves nowhere else. `nil` is
    /// the honest answer; a stand-in glyph would be a plausible value filling an unknown
    /// (`no-silent-fallbacks.md`).
    @Test("an emoji only Slack could know stays unknown")
    func customEmojiIsUnknown() {
        #expect(EmojiShortcode.glyph(for: ":collate:") == nil)
        #expect(EmojiShortcode.glyph(for: "") == nil)
        #expect(EmojiShortcode.glyph(for: "::") == nil)
    }

    /// Per entry rather than by count: a table that lost one token would still have thousands of
    /// entries, and only naming the pair that failed says where the pack went wrong.
    @Test("every packed pair parses back to itself")
    func packIsIntact() {
        let tokens = EmojiShortcode.packed.split(whereSeparator: \.isWhitespace)
        #expect(tokens.count.isMultiple(of: 2), "the pack is pairs; an odd count shifts them all")
        // Against 3826 tokens as generated. Not a count assertion — the per-pair loop below is
        // that — only a guard that the loop has something to iterate if generation half-failed.
        #expect(tokens.count > 3000, "the table looks truncated")

        for pair in stride(from: 0, to: tokens.count - 1, by: 2) {
            let shortcode = String(tokens[pair])
            let glyph = String(tokens[pair + 1])
            let looksLikeAShortcode = !shortcode.contains { !$0.isASCII }
            let looksLikeAGlyph = glyph.unicodeScalars.contains { !$0.isASCII }
            #expect(
                looksLikeAShortcode,
                "\(shortcode) is in a shortcode slot but is not one — the pack has shifted"
            )
            #expect(
                looksLikeAGlyph,
                "\(glyph) is in a glyph slot but is not one — the pack has shifted"
            )
            #expect(EmojiShortcode.glyph(for: shortcode) == glyph, "\(shortcode) parsed wrong")
        }
    }

    @Test("a status reads as a person reads it, and an unknown one reads as its shortcode")
    func statusDisplay() {
        #expect(UserStatus(emoji: ":headphones:", text: "In a meeting").display == "🎧 In a meeting")
        #expect(UserStatus(emoji: ":collate:", text: "Working").display == ":collate: Working")
    }

    /// An empty half must not leave a stray space: the menu puts this straight into a line of text.
    @Test("half a status has no dangling space")
    func halfAStatus() {
        #expect(UserStatus(emoji: ":headphones:", text: "").display == "🎧")
        #expect(UserStatus(emoji: "", text: "In a meeting").display == "In a meeting")
        #expect(UserStatus.cleared.display.isEmpty)
    }
}
