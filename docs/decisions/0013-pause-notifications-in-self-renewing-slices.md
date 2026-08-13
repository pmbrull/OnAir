# ADR-0013 — Pause notifications in self-renewing slices

- Status: Accepted
- Date: 2026-08-13

## Context

Being on camera means not reading Slack, so the status alone leaves notifications firing into a
meeting. Slack's `dnd.setSnooze` can silence them — but it wants a duration, and OnAir cannot know
how long the meeting runs. And unlike the status, a wrongly-stuck snooze is not merely stale: every
notification it eats is silently lost.

## Decision

Opt-in (`pauseNotifications`, default **off**), and the snooze is **sliced**: 30 minutes at a
time, renewed 5 minutes before expiry for as long as the devices stay in use and OnAir still owns
the snooze. Scopes grow by `dnd:read` and `dnd:write`.

The manners are the status's manners (ADR-0008), with one deliberate difference each way:

- **A snooze the user set themselves always wins** — there is no override toggle, because OnAir
  snoozing *harder* has no meaning and ending theirs early is pure loss. `snoozeVerdict` skips.
- **Ownership is the exact `snooze_endtime` Slack returned** from the last `setSnooze` — the API
  has no "who set this" field, so the endtime is the only fingerprint. A user who extends or ends
  the snooze mid-call changes it, and OnAir stands down (`SnoozeOwnership.stillOwns`).
- **Failures fail open and say so.** A failed renewal or release degrades to "notifications come
  back within one slice", noted in the menu — never a retry loop, because the slice expiring *is*
  the recovery. Snooze failures never throw into the status path: `missing_scope` on a
  pre-ADR-0013 connection must not make the engine retry a status write that already succeeded.

**Why slices, when the status deliberately has no safety net (ADR-0009)?** The two failures are
not symmetric. A stranded status is visible, embarrassing at worst, and correctable by anyone who
looks. Stranded DND is invisible to its victim and eats information — so this feature buys the
self-healing property ADR-0009 declined, at the cost of one API call per half hour of meeting.

`dnd:read` is required, not optional: without reading the current state, OnAir cannot tell a
user's snooze from its own, and both manners above would be unenforceable.

## Consequences

- Existing connections lack the scopes; the first snooze attempt fails `missing_scope` and the
  menu says to disconnect and reconnect once. The shared app's manifest already carries the new
  scopes; its dashboard copy must be updated once (`docs/runbooks/shared-app.md`, lifecycle table).
- A crash mid-call resumes notifications within 30 minutes with no help. Measured behaviour of
  the mechanism, not a promise: the slice *is* the timeout.
- The `dnd.*` shapes are documentation-derived until a live capture replaces them (GAP-0001) —
  including the quirk the parser leans on, that `snooze_*` keys are absent entirely when not
  snoozing.
- Toggling the option mid-call takes effect at the next call, not retroactively — the snooze
  starts on the status-apply path.
