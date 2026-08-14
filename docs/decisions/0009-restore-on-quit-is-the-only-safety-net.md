# ADR-0009 — Restore on quit is the only safety net

- Status: Accepted
- Date: 2026-08-12

## Context

If OnAir sets a status and then stops running — crash, force quit, a Mac that sleeps and never
wakes the process — the status stays on until the user notices. Slack offers `status_expiration`,
which would clear it server-side at a chosen time regardless of what happens locally.

## Decision

**No expiry, and no restore-on-next-launch.** The only net is `applicationShouldTerminate`, which
returns `.terminateLater`, puts the previous status back, and then lets the process go.

This was the product owner's explicit call: an expiring status is its own surprise — it vanishes
mid-meeting when the timer runs out — and a restore-on-launch acts on a belief about the world
that is hours stale by the time the app runs again.

`status_expiration: 0` is therefore sent **explicitly** on every write rather than omitted, so an
expiry set by something else cannot survive underneath and clear the status at a moment OnAir
would then attribute to the user.

**Amended by [ADR-0015](0015-carry-the-previous-status-expiry.md).** The zero is right for the
status OnAir *chooses*, which is what this decision was about. It was wrong for the status OnAir
*puts back*: a status written by Google Calendar carries the expiry that was going to clear it, and
sending zero on the restore strips the only clock it had. A restore now carries the expiry it read.

## Consequences

- **A crash mid-call leaves the status set until you fix it by hand.** This is a known, accepted
  cost. It is stated in the README rather than buried.
- `.terminateLater` is load-bearing: without it the process is gone before the request leaves the
  socket. It is also best-effort — AppKit's patience is finite and a hung network call will not
  hold quitting up forever.
- **Revisit if** this actually bites: the cheapest fix is an expiry set a few hours out and
  refreshed while the camera stays on, which keeps the net without the mid-meeting surprise.
