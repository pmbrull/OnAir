---
paths:
  - "**/*.swift"
---

# A fallback must say it fell back

**Constraint.** Any path that degrades — cannot reach Slack, cannot read a device name, cannot
register the login item, cannot bind the callback port — must surface that where the user and the
next agent can see it. In the app that means an `ActivityEntry` in the menu's history, or visible text
in Settings. Never a swallowed `try?` on a path the user is waiting on.

**Why.** OnAir's worst failure is not a crash. It is a status that quietly does not change while
the menu bar looks fine, or a "Launch at login" switch that is on and does nothing. A silent
fallback and a working app are indistinguishable from the outside, which makes the bug
unreportable.

Concretely, this rule is why:

- `LaunchAtLogin` exposes `awaitingApproval` separately from `isEnabled` — macOS holding a
  registration pending a switch in System Settings looks exactly like "it didn't work", and
  reporting it as success leaves a toggle that lies.
- `CaptureDevice.name` is `String?` rather than `"Unknown camera"`. An invented name in a
  diagnostic is worse than an absent one, because `doctor` is where someone goes to be told the
  truth about their hardware.
- `SlackWire.status` throws when a profile has no `status_text` key instead of reading it as
  cleared. "No status" and "we could not tell" must not be the same value — one of them permits an
  overwrite (ADR-0008). It throws on a missing or negative `status_expiration` for the same reason:
  "never expires" and "we could not tell" must not be either, because one of them strips somebody
  else's clock on the way back (ADR-0015).
- `EmojiShortcode.glyph(for:)` returns `nil` for a shortcode the vendored table has never heard of,
  and `UserStatus.displayEmoji` prints the shortcode itself. Echoing the input verbatim is not
  inventing a value; substituting a near-enough glyph would be. Settings says OnAir could not
  resolve it rather than calling it invalid, because a workspace custom emoji is real to Slack and
  unknowable here (ADR-0014).
- `SlackError` distinguishes `requiresReconnect` from everything else, so a dead token stops
  retrying and says so rather than failing quietly forever.

**Corollary — never invent a value to fill a hole.** A field that cannot be determined stays `nil`
or throws. This is the code-level form of the escape-hatch rule in `docs/gaps/README.md`.

**The one deliberate exception**, and why it is one: `CameraMonitor.isRunning` returns `false` when
a device will not answer. A device that fails to report is not *evidence* that it is running, and
defaulting to `true` would set a status because a virtual camera misbehaved. The comment at that
line says so.

**Reviewer rule.** `code-reviewer` flags fallbacks that return a plausible value without saying so.
