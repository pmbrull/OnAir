---
name: plan-feature
description: Write an execution plan to docs/plans/active/ before starting any non-trivial change — anything touching multiple files, adding a device signal or a Slack call, changing the policy engine, or more than a quick edit.
---

# plan-feature

Before non-trivial work, write ONE plan to `docs/plans/active/NNNN-<slug>.md` and agree it before
implementing. `NNNN` is zero-padded and monotonic (check both folders).

## The plan — all sections required

```
# Plan NNNN — <title>

- Status: Active
- Date: <YYYY-MM-DD>
- Input: <the ADR / gap / doc this derives from>

## Goal
One paragraph: what will be true when this is done that isn't now.

## Acceptance criteria
Checkable statements. ALWAYS include:
- [ ] `make verify` is green.
Then the change's own. If it touches `Sources/DeviceKit/`, one criterion MUST be `make doctor` on
real hardware or a case in `DeviceJourneyTests` — a fake restates our assumptions rather than
testing them. If it touches `Sources/SlackKit/` parsing, one MUST be captured Slack output.

## Affected modules
Which targets change, and which ARCHITECTURE invariants (A1–A7) they touch.

## Steps
Ordered; each independently verifiable.

## Risks
What could go wrong, and what you'll check to catch it early.

## Decision log
Append AS YOU WORK: `<date> — <decision> — <why>`. Surprises and course-corrections go here.
```

## Rules

- One plan per unit of work. If the work splits, split the plan.
- Keep the decision log current *while working*, not at the end. ADR-0011 started life as a line in
  a decision log.
- If you can't state the acceptance criteria, you don't understand the task yet. Resolve that first
  — and if nothing answers it, that's a `docs/gaps/` record, not a guess.
- A choice that will outlive this plan (a boundary, a default, a protocol) gets an ADR. Plans
  propose; ADRs decide.
- **A default that depends on real hardware or a real Slack workspace is not decidable at plan
  time.** Say in the plan that it will be measured, and measure it.
- On merge the plan moves to `docs/plans/completed/` with its Status line changed to `**Built**`.
