# Agent workflow

The loop every change goes through, and where the gap procedure interrupts it. Ported from the
`scholia` harness and scaled to this repo's profile: **TEAM = 1**, solo, review advisory. The skills
and reviewers referenced live in [`../.claude/skills/`](../.claude/skills/) and
[`../.claude/agents/`](../.claude/agents/).

Two automated gates sit under this loop. **Pre-commit hooks** (`make hooks`) catch the cheap
mistakes — a dangling ADR/GAP reference, a broken invariant, unformatted code, a build break.
**GitHub Actions** re-runs all of it on every PR with the tools guaranteed present, plus the full
suite and the bundle assembly. Neither replaces step 3: the device journey tests need real capture
hardware, and CI has none.

One thing the loop's last step now means more than it did: since ADR-0018, **merge is release**. The
same push that lands the change derives a version from its commit subject, notarizes, publishes and
updates the tap — so the PR title is a shipped artefact, and `merge` is the point of no return rather
than `git tag`.

## The loop

```
  plan ─▶ implement ─▶ verify ─▶ review ─▶ merge
                          │
                          ▼  (same step fails twice)
                     harness-gap ─▶ fix the harness ─▶ retry from a clean session
```

1. **Plan** — `plan-feature`: write `docs/plans/active/NNNN-<slug>.md`. Agree it before
   implementing.
2. **Implement** — do the steps; keep the plan's decision log current *as you go*.
3. **Verify** — `verify-change`: `make verify` green → exercise the real app → run
   `make doctor` and the **device journey tests against real hardware**. **`make verify` alone is
   not "done".**
4. **Review** — pre-merge self-review, each reviewer given the `git diff`:
   - `code-reviewer` — is it *correct*: logic, edge cases, concurrency, resource lifecycle, tests.
   - `security-reviewer` — is it *safe*: what leaves the machine, what is stored, what is executed.
   - `convention-reviewer` — diff vs [`../.claude/rules/`](../.claude/rules/).
   - `architecture-reviewer` — diff vs [`../ARCHITECTURE.md`](../ARCHITECTURE.md) invariants A1–A7.
   - `doc-gardener` — which docs went stale; apply its proposed edits.
5. **Merge** — `open-pr`. **An agent opens the PR; a human merges.** On merge the plan moves to
   `docs/plans/completed/`.

## Where harness-gap interrupts

If any step fails **twice for the same reason**, do not try a third time and do not hand-write past
it. Invoke `harness-gap`: record `docs/gaps/open/NNNN-<slug>.md`, and **the harness fix becomes the
work**.

The judgement call is what "the same reason" means. A step that fails three times with three
*different*, each-time-narrower diagnoses is converging, not stuck — getting Swift Testing to run
under Command Line Tools went module-not-found → link-ok-but-no-rpath → wrong-rpath, and each error
named the next fix. A step that fails twice with the *same* error is stuck, and a third attempt is
guessing.

## Reviewers are read-only by construction

The five reviewers have tool lists with **no Edit/Write/Bash**, by design — they report and propose;
the author applies. Three check *conformance* (rules, architecture, docs); `code-reviewer` checks
whether the code is *correct*, and `security-reviewer` whether it is *safe*. Those are the two
substance dimensions `make verify` does not cover.

## What this repo verifies that a unit test cannot

OnAir's claims are about **other people's undocumented behaviour on this machine**: CoreMediaIO's
and CoreAudio's device enumeration across every virtual-device vendor, Slack's JSON, and whether a
browser will make the `https:` → `http://127.0.0.1` hop the callback relay rests on. A fixture that
restates our assumptions proves nothing about any of them.

So `Tests/DeviceKitTests/DeviceJourneyTests.swift` runs against **this Mac's real hardware** and
disables itself when there is none, asserting **per device** and naming the ones that fail — an
aggregate count would go green while a whole class of device silently failed to parse. And
`LoopbackTests` binds a real listener and drives it with `URLSession`, because a port that will not
bind and a request split across TCP segments are not failures a string can reproduce. The relay page
in `site/` is the one thing no Swift test reaches — it runs in a browser, so it was measured with
one, in three engines, over real TLS (ADR-0019).

ADR-0011 is what this bar bought: the microphone default was wrong, and only real hardware said so.

## What changes when this stops being a solo repo

- Advisory review → **required approval** on a protected `main`.
- The five reviewers → **required CI checks** alongside the two the workflow already produces.
