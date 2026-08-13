# Plan 0003 — Pause notifications while on camera

- Status: Active
- Date: 2026-08-13
- Input: "can you also pause notifications in Slack? not just status update" — after the first
  live connect worked (plan 0002)

## Goal

While a watched device is in use and the user has opted in, Slack stops notifying them — via
`dnd.setSnooze` — and notifications resume when the device goes idle, with the same manners the
status has: never clobber a snooze the user set themselves, never end one they extended, and fail
open (notifications resume by themselves) rather than closed.

## Acceptance criteria

- [x] `make verify` is green.
- [x] `pauseNotifications` defaults **off** — additive feature, and existing connections lack the
      scope until they reconnect.
- [x] The snooze verdict and the ownership rule are pure functions in `StatusKit` with tests (A3):
      an already-active snooze is skipped, and a snooze the user extended mid-call is left alone.
- [x] The snooze is sliced and refreshed, never open-ended: a crash mid-call means notifications
      resume within one slice on their own — deliberately *unlike* the status (ADR-0009), because
      missed notifications are silent lost information and a stale status is merely stale.
- [x] A missing `dnd:write` surfaces as "Reconnect Slack" in the menu, not a silent no-op.
- [x] The manifest (README + link) and the runbooks carry the new scopes, with the note that scope
      changes force every user to reconnect.
- [x] Wire parsing pinned against fixtures; marked documentation-derived under GAP-0001 until a
      live capture replaces them.

## Affected modules

`StatusKit` (SnoozeState, policy field, verdicts), `SlackKit` (three `dnd.*` calls, parsing),
`OnAir` (coordinator wiring, Settings toggle). Invariants: A3 is the load-bearing one — the two
rules go in `StatusKit`; A4 untouched; scopes grow by `dnd:read` + `dnd:write` (ARCHITECTURE:
a new scope is a decision → ADR-0013).

## Steps

1. `StatusKit`: `SnoozeState`, `StatusPolicy.pauseNotifications` (+ slice constants), the snooze
   verdict and ownership rules. Tests.
2. `SlackKit`: `SlackWire` parsers for `dnd.info`, `dnd.setSnooze`, `dnd.endSnooze` + fixtures;
   `SlackClient.dndInfo()/setSnooze(minutes:)/endSnooze()`.
3. Coordinator: snooze on apply (verdict-gated), slice refresh while active, release on
   restore/pause/disconnect/quit (ownership-gated). DND failures never block the status path.
4. Settings › Behaviour: the toggle, with the reconnect caveat spelled out.
5. Manifest + README + runbooks + ADR-0013; GAP-0001 notes the new documentation-derived fixtures.
6. `make verify`, reviewers on the diff, push.

## Risks

- **`dnd.info`'s shape.** Slack documents `snooze_enabled`/`snooze_endtime` as present only while
  snoozing — an absent key here genuinely means "not snoozing", unlike the profile where absence
  means schema change. The parser treats it so, and the fixture pins both shapes. GAP-0001 applies.
- **Ownership by endtime.** We recognise "our" snooze by the endtime Slack returned; the user
  extending it changes the endtime and we stand down. If Slack rounds the timestamp differently
  between set and info, ownership breaks — the live check after reconnect is the measurement.
- **Scope upgrade path.** Existing token lacks `dnd:write`; first snooze fails `missing_scope` →
  `requiresReconnect` already turns the menu red. Verify that path reads clearly.

## Decision log

- 2026-08-13 — Slices (30 min, refreshed 5 min before expiry) instead of one long snooze — a
  crash mid-call self-heals within a slice, which is the opposite trade to the status (ADR-0009)
  because a stale status is visible and correctable while missed notifications are silently lost.
- 2026-08-13 — `dnd:read` as well as `dnd:write`: without reading, OnAir cannot tell a snooze the
  user set from its own, and the never-clobber rule (ADR-0008's sibling) would be unenforceable.
