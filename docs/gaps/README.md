# Gaps

A **gap** is a question the profile and the code do not answer but that some piece of work needs
answered. Gaps are findings, not failures. One is recorded when a plan, a review, or a verification
sweep finds one.

## Layout

The folder **is** the status:

- `open/` — still unanswered. A gap is **created here.**
- `closed/` — a decision has answered it. `git mv` it here and fill `closed_by:` with the ADR.

## The escape-hatch rule (read this)

> When you hit a decision the profile and the code do not answer, **do not invent a default.** Open
> a gap, surface it, and either wait or work around it explicitly. An absent answer is a finding to
> record, not a blank to fill with what seems sensible.

This matters here because OnAir sits on three things nobody publishes a contract for: CoreMediaIO's
and CoreAudio's enumeration behaviour across every virtual-device vendor, Slack's JSON, and the
version of LibreSSL that happens to ship with a given macOS. ADR-0011 exists because one of those
turned out not to behave the way the design assumed — and it was found by running against real
hardware, not by reasoning.

## Open

| Gap | Title |
| --- | --- |
| [0001](open/0001-slack-fixtures-are-documented-not-captured.md) | The Slack response fixtures are documentation-derived, never captured |
| [0002](open/0002-pkce-flow-unverified-against-a-live-workspace.md) | The PKCE flow and its token longevity are unverified against a live workspace |
| [0003](open/0003-one-unexplained-keychain-deposit-after-the-fix.md) | One run deposited seven keychain items after the ADR-0016 fix, and nothing has reproduced it |

## Closed

*(none yet)*

## Gap-record format

```
---
id: GAP-NNNN
title: <one line>
status: open | closed
impact: <what it blocks>
opened: YYYY-MM-DD
closed_by: <ADR ref, when closed>
---

**Question.** The specific thing that is unanswered.

**Why it's open.** What points at it, and why a default is unsafe.

**Blocks.** What cannot proceed (or proceeds provisionally) until it is decided.

**Provisional handling.** If work went ahead, exactly what was assumed and where.
```

## Keeping references honest

Every `GAP-NNNN` and `ADR-NNNN` in the tree is a promise that the record exists.
`./scripts/check-references.sh` proves it on every commit and in CI — a dangling reference is bad,
but a *resolvable* one pointing at the wrong record is worse, because a reader will find it
coherent enough not to question.
