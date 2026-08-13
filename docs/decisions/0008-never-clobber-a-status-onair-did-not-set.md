# ADR-0008 — Never clobber a status OnAir did not set

- Status: Accepted
- Date: 2026-08-12

## Context

Every other failure in this app is recoverable by waiting or pressing a button. Overwriting a
status the user typed is different: the old text is gone, and OnAir is the only thing that knew it.

There are two moments where it can happen — when the camera comes on over an existing status, and
when the camera goes off over a status the user changed mid-call.

## Decision

Two rules, both in `StatusKit` so both are tested:

1. **`StatusPolicy.verdict(forLive:)`** — if Slack already holds a status and
   `overrideExistingStatus` is off, OnAir writes nothing and says so in the menu. The verdict is
   remembered for the rest of that stretch of activity (`Applied.skipped`) so the profile is not
   re-read on every tick, and forgotten when the devices go idle so the next call decides afresh.
   Either half alone — an emoji with no text, or text with no emoji — counts as a status.
2. **`StatusEngine.stillOwns(_:)`** — a restore happens only if what Slack holds right now is
   byte-identical to what OnAir wrote. Change your status by hand during a call and OnAir stands
   down, leaving your edit alone and saying so.

A corollary that is easy to get wrong: when the emoji or text is edited mid-call, OnAir re-applies
but must **not** re-read the live status to stash as `previous` — the live status is its own, and
stashing it would make the eventual restore a no-op that strands the status forever. The engine
exposes `appliedPrevious` precisely so the caller can tell a fresh apply from a refresh.

`SlackWire.status` throws rather than returning `.cleared` when a profile has no `status_text` key.
Reading a schema change as "no status" would make rule 1 conclude there is nothing to protect.

## Consequences

- The default is conservative: with `overrideExistingStatus` off, a user who lives with a permanent
  status gets nothing from OnAir until they turn the toggle on. The menu says why, every time.
- A restore costs an extra `users.profile.get`. Two calls per meeting is nothing against Slack's
  Tier 3 limit.
