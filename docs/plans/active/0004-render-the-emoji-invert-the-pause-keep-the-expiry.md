# Plan 0004 — Render the emoji, invert the pause, keep someone else's expiry

- Status: Active
- Date: 2026-08-13
- Input: a screenshot of the menu plus three notes — "`:headphones:` is not rendering. I want it to
  render"; "instead of *Pause OnAir*, it should be the other way around: by default enabled and say
  *OnAir is running*"; and "once you add back the past slack status, if that status came from third
  party tools like google calendar, then *in a meeting* status is never re-resolved. How could we
  solve this?"

## Goal

Three changes, two cosmetic and one that fixes a status OnAir strands.

1. The menu shows `🎧 In a meeting`, not `:headphones: In a meeting`.
2. The switch reads in the affirmative — on means running — so the resting state of the app is the
   on state of the control.
3. A status OnAir restores expires the way it was going to expire before OnAir touched it.

Number three is the real bug, and it is worth stating precisely, because the screenshot shows it
happening. Google Calendar's Slack app does not clear "In a meeting" when the meeting ends: it
writes the status **with `status_expiration` set to the end of the event** and lets Slack clear it.
OnAir reads that status as `(emoji, text)` only — the expiry is dropped on the floor — and then
`SlackWire.profileSetBody` sends `status_expiration: 0` on *every* write, restores included. So the
status that comes back is the same words with the clock removed, and nothing will ever clear it:
Google Calendar has already done its half of the job and will not revisit it. The user is left
"In a meeting" until they notice and fix it by hand.

ADR-0009 chose `status_expiration: 0` deliberately, and for OnAir's *own* status that reasoning
still holds. It was never a decision about someone else's.

## Acceptance criteria

- [x] `make verify` is green.
- [x] `:headphones:` renders as 🎧 in the menu and in Settings; a shortcode with no known glyph —
      a workspace custom emoji like `:collate:` — renders as the shortcode text, never as a
      substituted or guessed glyph (`no-silent-fallbacks.md`).
- [x] The lookup table is data with a stated provenance and a script that regenerates it; no new
      package dependency (ADR-0004).
- [x] The menu's switch reads "OnAir is running" and is **on** in the default policy. The
      inversion is a property in `StatusKit` with a test, not a `Binding` trick in the view (A3).
- [x] `SlackWire.status` parses `status_expiration`, and a profile without the key throws rather
      than reading as "no expiry" — "never expires" and "we could not tell" must not be the same
      value, for the same reason `status_text` throws (ADR-0008).
- [x] The expiry rides along with the stashed status and is written back on restore, so Slack
      clears it at the moment it was always going to.
- [x] A stashed status whose expiry passed *during* the call is **cleared**, not put back — and
      the menu says which of the two happened.
- [x] OnAir's own status is still written with `status_expiration: 0` (ADR-0009 unchanged).
- [x] `doctor --slack` prints the live status's expiry, so the next person can see the field this
      bug was about.

## Affected modules

`StatusKit` — `EmojiShortcode` + the generated table, `StatusPolicy.isRunning`, `LiveStatus` and
its restore rule. `SlackKit` — `SlackWire.status`/`profileSetBody`, `SlackClient.currentStatus`/
`setStatus`. `OnAir` — menu, Settings, coordinator, doctor.

Invariants: A3 is the load-bearing one again — the restore rule ("expired → clear") and the
inversion are pure functions in `StatusKit`, not `if`s in `AppCoordinator`. A1/A2/A4/A5 untouched;
no new scope, so nobody has to reconnect.

## Steps

1. `scripts/generate-emoji-table.sh` → `Sources/StatusKit/EmojiTable.swift`; `EmojiShortcode`
   with the honest fallback; `UserStatus.display`. Tests.
2. `StatusPolicy.isRunning`. Menu switch and wording. Test that it is the inverse of `paused` in
   both directions and that `standard` reads as running.
3. `LiveStatus` + `restoration(now:)` in `StatusKit`, with tests for never-expires, expires-later
   and expired-during-the-call.
4. `SlackWire`: parse `status_expiration`; `profileSetBody(_:expiresAt:)`. Fixtures for a profile
   carrying a live expiry (documentation-derived → GAP-0001).
5. Coordinator: thread `LiveStatus` through apply/restore/quit/disconnect; two history wordings.
   Doctor prints the expiry.
6. ADR-0014 (emoji table), ADR-0015 (carry the expiry; amends ADR-0009). Index both. README and
   `docs/index.md` where they describe the restore.
7. `make verify`, `make doctor-slack` — the live read is what confirms `status_expiration` is
   really in the profile payload — reviewers on the diff, PR.

## Risks

- **`status_expiration`'s presence is documentation-derived** (GAP-0001). Throwing on absence is
  consistent with `status_text`, but it means a wrong assumption breaks reading the status rather
  than degrading. `make doctor-slack` against the live workspace is the measurement, and it is
  read-only, so it costs nothing to run.
- **Slack's behaviour on a past `status_expiration`** is not documented as an error. OnAir never
  sends one — a passed expiry becomes a clear — so the question does not arise, which is the
  cheaper answer than finding out.
- **The table will not resolve custom emoji.** `:collate:` is workspace data that only Slack can
  resolve, and resolving it would mean a new scope and an `emoji.list` call. The fallback shows
  the shortcode, which is what the menu shows today, so nothing regresses.
- **File length.** The generated table is ~1900 entries; packed as whitespace-separated pairs it
  is a few hundred lines and stays under SwiftLint's `file_length`. If it ever crosses, the fix is
  a second generated file, not a raised threshold.

## Decision log

- **2026-08-13 — `status_expiration` is really there.** `make doctor-slack` against the live
  workspace parsed a profile with a status and printed `expires never`, so the key is present and
  an integer on that shape. The throw-on-absence choice is no longer resting on documentation
  alone; GAP-0001 records exactly how far that measurement reaches (not to the empty-status shape).
- **2026-08-13 — the table is the full standard set, not a curated one.** A curated subset produces
  the same "my emoji isn't rendering" report the first time somebody picks one nobody listed. The
  cost is a ~350-line generated file and a script to regenerate it (ADR-0014).
- **Not done: exercising the built app.** `make app` assembles, but the installed OnAir was running
  and the camera was in use at the time, so launching a second instance would have raced the first
  one over a live Slack status. Left for the human to do off-camera.
