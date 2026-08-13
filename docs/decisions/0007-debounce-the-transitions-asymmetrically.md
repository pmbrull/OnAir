# ADR-0007 — Debounce the transitions, asymmetrically

- Status: Accepted
- Date: 2026-08-12

## Context

Raw device transitions are not meeting boundaries. Cameras blip when an app enumerates them at
launch. Meetings run back to back, with twenty seconds between leaving one and joining the next.
Writing to Slack on every raw edge produces a status that flickers in front of colleagues.

## Decision

Two delays, deliberately different:

- **`onDelay` = 3s.** Long enough to swallow an enumeration blip, short enough that nobody notices.
- **`offDelay` = 60s.** Long enough to bridge the gap between consecutive meetings.

Both configurable. **Pause bypasses both** and takes effect immediately — a pause that waited out
`offDelay` would not be a pause.

The debounce lives in `StatusEngine`, which is pure: it takes `now` as a parameter and returns a
`wakeAt` for the caller to schedule. No timer, no `Date()`, no `Task` inside the engine.

## Consequences

- The engine's whole behaviour is testable by passing dates. Sixteen cases cover it, including the
  two that matter most: a blip shorter than `onDelay` never writes, and a gap shorter than
  `offDelay` neither restores nor re-applies.
- A restore can lag a real end-of-day by a minute. That is the intended trade.
- The caller must actually honour `wakeAt`. `AppCoordinator` cancels and reschedules one task per
  decision; a dropped wake-up would leave a status set with nothing pending to clear it.
