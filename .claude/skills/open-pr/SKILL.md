---
name: open-pr
description: Open a pull request with the standard description and pre-merge checklist. An agent opens the PR and NEVER self-merges, even in a solo repo.
---

# open-pr

**An agent opens the PR and never merges it.** A human merges. This holds even solo: the PR is the
one moment the diff is read as a whole, and an agent that merges its own work removes that moment.

## Commit & PR-title format — Conventional Commits (advisory)

`type(scope): description` — `feat`, `fix`, `docs`, `chore`, `build`, `refactor`, `test`; `!` or a
`BREAKING CHANGE:` footer for an incompatible change.

## PR description

```
## Summary
What changed and why, in 2–3 sentences. Link the plan: docs/plans/active/NNNN-<slug>.md.

## Acceptance criteria
- [ ] <criterion> — how checked
- [ ] `make verify` green
- [ ] `make doctor` run against real hardware (or: not applicable, because …)

## Verification
Paste the tail of `verify-change`: the `make verify` result, the real-app exercise, and which
journey cases actually ran rather than skipping.
Subagent review: which reviewers ran, their findings, and how each was addressed or dismissed.

## Risks / follow-ups
What to look hardest at; any gap opened.
```

## Pre-open checklist

- [ ] **PR base is `main`** — cut from `main`, targets `main`, no stacked PRs.
- [ ] `verify-change` passed — gate green, journeys run, no residue.
- [ ] Pre-merge self-review run and resolved: `code-reviewer`, `security-reviewer`,
      `convention-reviewer`, `architecture-reviewer`, `doc-gardener`.
- [ ] The plan's decision log is current.
- [ ] **Every `GAP-NNNN` and `ADR-NNNN` in the diff resolves to a real record**, and points at the
      *right* one. `./scripts/check-references.sh`.
- [ ] **No credential committed, and none introduced at runtime.** A token in a fixture is a token
      in git history forever; assemble fake ones so they cannot match the check
      (`Tests/SlackKitTests/SlackResponseFixtures.swift` shows the shape).
- [ ] **No new capture API.** `AVCaptureSession` and friends are a blocker, not a review comment
      (A5, ADR-0001).
- [ ] Docs updated, or `doc-gardener` reports none stale. The README's TODO list is the
      authoritative backlog — a shipped item moves out, a new limitation moves in.

## On merge (performed by a human, not the agent)

- [ ] `git mv docs/plans/active/NNNN-<slug>.md docs/plans/completed/`, changing the `Status:` line
      to `**Built**` in the same commit.
