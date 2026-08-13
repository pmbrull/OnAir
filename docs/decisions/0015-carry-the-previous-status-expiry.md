# ADR-0015 — Carry the previous status's expiry across a restore

- Status: Accepted
- Date: 2026-08-13
- Amends: [ADR-0009](0009-restore-on-quit-is-the-only-safety-net.md)

## Context

Reported from a real menu: "once you add back the past Slack status, if that status came from a
third-party tool like Google Calendar, then *in a meeting* is never re-resolved."

It is not re-resolved because nothing is coming to re-resolve it. Google Calendar's Slack app does
not clear your status at the end of the event — it writes the status **with `status_expiration` set
to the event's end time** and lets Slack clear it. That is the entire mechanism, and it is one-shot.

That mechanism is **inference, not measurement**: the symptom is a user report, and the rest is read
off Slack's API. GAP-0001 carries the question and names the one-line way to answer it. The decision
below does not depend on it — dropping an expiry that Slack has told us about is wrong whoever set
it — but the story in this Context would change if the inference is wrong.

OnAir read that status as `(emoji, text)` and dropped the expiry on the floor. Then
`SlackWire.profileSetBody` sent `status_expiration: 0` on *every* write, restores included. So what
came back after the call was the same words with the clock removed, owned by nobody: Google
Calendar has already done its half of the job and will not revisit it, and OnAir has just recorded
that it no longer owns the status. The user stays "In a meeting • Google Calendar" until they
notice and fix it by hand — which is exactly the failure ADR-0008 exists to prevent, arrived at
from the other direction.

ADR-0009 chose `status_expiration: 0` deliberately and that reasoning still holds — for OnAir's
*own* status. It was never a decision about somebody else's.

## Decision

**The expiry is part of what gets stashed, and part of what gets put back.**

- `LiveStatus` — a status *as Slack holds it*: the pair OnAir writes, plus the `expiresAt` it does
  not. `SlackWire.status` parses `status_expiration`, and a profile missing the key **throws**,
  for the same reason `status_text` does: "never expires" and "we could not tell" must not be the
  same value, because one of them silently strips somebody else's clock.
- `LiveStatus.restoration(now:)` in `StatusKit`, so the rule is a pure function with tests (A3):
  - no expiry → put the status back as it was;
  - expiry still ahead → put it back **with that expiry**, so Slack clears it at the moment it was
    always going to;
  - expiry already passed → **clear instead**. Slack would have cleared that status during the
    call, so putting the words back would hand the user a status they had already stopped having.
    "Passed" carries a ten-second horizon, because the decision and the write are a network round
    trip apart and an expiry two seconds out would otherwise reach Slack already in the past — the
    one input Slack's documented behaviour is silent about.
- `LiveStatus.effectiveStatus(now:)` is the same predicate on the way *in*: the override rule
  (ADR-0008) sees an expired status as cleared. Without it the two halves contradict each other —
  the restore treats a passed expiry as gone while the override rule treats it as a status to
  protect, and OnAir would then write nothing for a whole call because of a status Slack has
  already retired.
- OnAir's own status is still written with `status_expiration: 0`. `profileSetBody`'s parameter
  defaults to `0`, and the restore is the only caller that passes anything else.
- `stillOwns` compares the expiry too. OnAir writes `0`, so an expiry that has appeared under the
  same words is evidence somebody else wrote them.

## Consequences

- **A meeting that ends while you are still on camera clears your status** rather than restoring
  it. That is the correct outcome and it is not obvious, so the menu says which of the two
  happened: *"In a meeting • Google Calendar" expired during your call — cleared your status
  instead of putting it back.*
- **OnAir now writes a non-zero `status_expiration`** — once, on a restore, and only ever the value
  it read. It never chooses one, so ADR-0009's "no expiry as a crash net" is intact.
- **Every path that puts a status back now checks ownership first.** `disconnect()` did not, and a
  blind write there stopped being merely wrong the moment a passed expiry could make it a *clear*:
  deleting a status the user typed rather than replacing it. Quit, restore and disconnect now make
  the same ADR-0008 check, and a read that fails counts as "not ours" — the stranded status ADR-0009
  already accepts is the cheaper of the two mistakes.
- **A profile without `status_expiration` breaks reading the status** instead of degrading. Its
  presence is documentation-derived (GAP-0001); `make doctor-slack` prints the field, so the live
  check that closes that gap now covers this too.

## Alternatives

- **Leave it.** The status is stranded until noticed by hand — the single failure this app exists
  to avoid.
- **Re-read the profile at restore time and merge.** Same call count, but it cannot distinguish
  "the expiry is gone because it fired" from "the expiry is gone because OnAir overwrote it",
  which is the thing being fixed.
- **Restore a passed expiry verbatim** and let Slack sort it out. Slack does not document what it
  does with an expiry in the past, and finding out costs more than deciding it here.
