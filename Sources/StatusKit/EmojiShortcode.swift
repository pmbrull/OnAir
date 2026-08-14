import Foundation

/// Slack's shortcodes, turned into the glyph a person reads.
///
/// Slack's API speaks `":headphones:"` and nothing else, so that is what `UserStatus.emoji` holds
/// and what OnAir sends. Showing the user the same string is showing them the wire format — hence
/// this table, and hence it living in the target that decides rather than in a view (A3, ADR-0014).
///
/// The table is generated: see `scripts/generate-emoji-table.sh` and `EmojiTable.swift`.
public enum EmojiShortcode {
    /// The glyph for `":headphones:"`, or `nil` when the table has never heard of the shortcode.
    ///
    /// `nil` is the honest answer for every workspace custom emoji — `:collate:` is data held in
    /// one Slack workspace, and only Slack can resolve it. Substituting a stand-in glyph would be
    /// inventing a value (`no-silent-fallbacks.md`); callers show the shortcode instead, which is
    /// what the menu showed before this table existed.
    /// Deliberately lenient about the colons `UserStatus.emoji` documents as required: this runs
    /// against a Settings field on every keystroke, and refusing to render `:headphones` while the
    /// user is still typing the closing colon would make the preview flicker. Slack is *not*
    /// lenient — see `isWireShaped`, which is what Settings warns on.
    public static func glyph(for shortcode: String) -> String? {
        let key = shortcode.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !key.isEmpty else { return nil }
        return table[key]
    }

    /// Whether this is the form Slack's API accepts: colons included.
    ///
    /// Slack answers a bare `headphones` with `ok: true` and quietly keeps the old emoji, which
    /// from the outside is indistinguishable from OnAir failing to write — so the one place that
    /// can catch it is the field where it was typed.
    public static func isWireShaped(_ shortcode: String) -> Bool {
        let trimmed = shortcode.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 2 && trimmed.hasPrefix(":") && trimmed.hasSuffix(":")
    }

    /// Parsed once, on the first status that needs rendering, from the packed pairs. Alternating
    /// tokens rather than a dictionary literal: see the note in the generated file.
    private static let table: [String: String] = {
        var table: [String: String] = [:]
        var pending: Substring?
        for token in packed.split(whereSeparator: \.isWhitespace) {
            if let shortcode = pending {
                table[String(shortcode)] = String(token)
                pending = nil
            } else {
                pending = token
            }
        }
        return table
    }()
}
