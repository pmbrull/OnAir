# docs/

The knowledge base. What each thing is, and when to reach for it.

| Path | Purpose |
|---|---|
| [`agent-workflow.md`](agent-workflow.md) | **Start here.** The loop every change goes through, and the harness-gap valve that interrupts it. |
| [`dev-loop.md`](dev-loop.md) | How to build, run and exercise OnAir locally — the commands and what a healthy result looks like. |
| [`profile.md`](profile.md) | The project profile: shape, stack, team, verification bar, and what is forbidden. |
| [`decisions/`](decisions/) | ADRs — every load-bearing choice, with the live reasoning and the alternative it beat. |
| [`gaps/`](gaps/) | Questions nothing answers yet, and the escape-hatch rule: record, don't guess. |
| [`plans/`](plans/) | Units of work proposed before they're built; `active/` vs `completed/`. |
| [`runbooks/`](runbooks/) | Manual procedures. [`first-run.md`](runbooks/first-run.md): the user side — connect, get past the certificate warning. [`shared-app.md`](runbooks/shared-app.md): the maintainer side — create the shared Slack app, once ever. |

Structural intent (module boundaries, dependency directions, invariants) lives one level up in
[`../ARCHITECTURE.md`](../ARCHITECTURE.md); the daily table of contents is
[`../CLAUDE.md`](../CLAUDE.md).

## Where things go

A choice that outlives its plan gets an **ADR**. A question with no answer gets a **gap**. A unit of
work gets a **plan**. Design narrative about *why the code looks like this* goes in a doc comment at
the site — this repo is small enough that a `docs/internals/` tree would be ceremony.
