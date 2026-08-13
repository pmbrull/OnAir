# ADR-0014 — Render shortcodes from a vendored table

- Status: Accepted
- Date: 2026-08-13

## Context

Slack's API takes `":headphones:"` and rejects the glyph, so that is what `UserStatus.emoji` holds
and what OnAir sends. The menu was showing the same string back to the user, which is showing them
the wire format: the panel read `:headphones: In a meeting`.

Nothing in Foundation maps a shortcode to a glyph. The vocabulary is not derivable either — Unicode
names 🎧 HEADPHONE and 🔴 LARGE RED CIRCLE, while the shortcodes are `headphones` and `red_circle`.
Deriving one from the other gets roughly two thirds of the set right, and a wrong glyph rendered
confidently is worse than a shortcode rendered honestly.

## Decision

**Vendor the table.** `scripts/generate-emoji-table.sh` fetches github/gemoji — the shortcode
vocabulary Slack and GitHub share, MIT licensed — and writes `Sources/StatusKit/EmojiTable.swift`:
1913 pairs packed as whitespace-separated `shortcode glyph` tokens, parsed once, lazily.

Packed rather than a `[String: String]` literal because a 1913-entry dictionary literal is minutes
of Swift type-checking. Generated rather than hand-curated because a curated subset produces the
same complaint again the first time somebody picks an emoji nobody thought of.

`EmojiShortcode.glyph(for:)` returns `String?`, and **`nil` is a real answer**: a workspace custom
emoji like `:collate:` is data held inside one Slack workspace and resolvable nowhere else.
`UserStatus.displayEmoji` falls back to the shortcode itself, which is what the menu showed before
this table existed, so an unknown emoji degrades to the old behaviour rather than to a wrong glyph
(`.claude/rules/no-silent-fallbacks.md`).

This is not a dependency in the sense ADR-0004 forbids: nothing is fetched at build or run time,
nothing executes, and the data changes only when Unicode does. `Package.swift` is untouched.

## Consequences

- **Custom emoji never render.** Resolving them would mean an `emoji.list` call and the
  `emoji:read` scope — and a new scope forces every existing user to reconnect (ARCHITECTURE:
  "where a new Slack call goes"), which is a steep price for a picture. Settings says so in as many
  words instead of leaving the user to guess whether they typed it wrong.
- **The table needs regenerating** when Unicode adds emoji. The script is one command and the
  suite checks the pack per pair, so a bad regeneration fails loudly rather than shifting every
  lookup by one.
- `StatusKit` grows a ~350-line generated file. It is the only generated file in the repo, and it
  is marked as one on line 1.

## Alternatives

- **A curated 40-entry table.** Cheaper, and wrong the first time someone picks `:coffee:`.
- **Derive from Unicode character names** via `StringTransform`. Free, and silently wrong for about
  a third of the set — the exact failure `no-silent-fallbacks.md` exists to prevent.
- **Ask Slack** with `emoji.list`. It is the only way to resolve custom emoji, and it costs a new
  scope, a new call, a cache and a reconnect for every user. Worth revisiting only if custom emoji
  turn out to be what people actually pick.
