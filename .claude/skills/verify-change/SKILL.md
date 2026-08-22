---
name: verify-change
description: Run the full local verification sequence before a change is considered done or a PR is opened. Use after implementing, and again right before merge.
---

# verify-change

Run these in order. Stop at the first failure and fix it — but if the SAME step fails twice for the
SAME reason, stop and use `harness-gap` instead of hand-fixing.

> **Two steps are mandatory before anything is "done".** (1) `make doctor` against real hardware
> when the change touches device handling (step 3). (2) The pre-merge review subagents (step 5). A
> green `make verify` is necessary but **not** sufficient.

## 1. The gate — `make verify` (pass = exit 0)

| sub-step | pass criterion |
|---|---|
| references | every ADR/GAP reference resolves; records indexed; gap status matches its folder |
| arch | invariants A1 (deps), A2 (headless kits), A4 (token in Keychain), A5 (no capture), A6 (no PKCS#12 import), A7 (relay page and listener agree) hold |
| version-rule | `scripts/next-version.sh` answers all 37 cases in the table (ADR-0018) |
| fmt-check | no unformatted Swift (**skips if swiftformat is absent** — install it, or CI will find what you did not) |
| lint | no SwiftLint issue (same caveat) |
| build | every target compiles, kits under Swift 6 language mode |
| test | the whole suite passes |

`make test`, not `swift test` — see `docs/dev-loop.md`.

## 2. Exercise the real app (if the change has runtime behaviour)

- `make app` — pass = `.build/OnAir.app` exists and codesigns.
- `make run`, then open Photo Booth. Pass = the menu-bar glyph fills in within a few seconds and the
  panel's last line names what it did. Close it; the status goes back after `offDelay`.
- Quit OnAir mid-call and check Slack: the status must be back (ADR-0009).

## 3. Against real data — MANDATORY for the areas it covers

- **Device handling** → `make doctor`. Read the whole inventory, not just the summary. The
  microphone rows are the ones that have already been wrong once (ADR-0011).
- `make test` runs `DeviceJourneyTests` against this Mac's hardware and **disables itself** when
  there is none. If it skipped and you changed `DeviceKit`, you have not verified the change.
- **Slack parsing** → capture fresh output rather than editing a fixture to match the code:
  ```sh
  curl -s -H "Authorization: Bearer $SLACK_USER_TOKEN" https://slack.com/api/users.profile.get
  ```
  and see GAP-0001, which is open precisely because this has not been done yet.
- **The OAuth flow** → `LoopbackTests` drives a real listener with `URLSession`. If you touched
  `SlackKit/OAuth/`, watch them actually run.
- **The relay page** → `site/` is the redirect URL (ADR-0019), and no Swift test reaches it because
  it runs in a browser. If you touched it, serve `site/` and drive the callback with a real browser
  against a listener on the port, for a code, for a decline, and for no parameters at all.

## 4. No residue

- `ls ~/Library/Application\ Support/OnAir` — nothing should accumulate. A `loopback.p12` there
  predates ADR-0019 and is no longer written or read; a *new* one means a certificate came back.
- `ls $TMPDIR | grep onair` = empty. Leftovers mean a path escaped.
- No new Keychain items beyond `slack-token`, `slack-renewal` (ADR-0020) and `slack-client` under
  `io.umamidata.onair`.

## 5. Pre-merge self-review by subagents — MANDATORY

Run the read-only reviewers on the diff **in parallel** (one message, several `Agent` calls), give
each the actual diff, then address or consciously dismiss every finding:

| subagent | judges |
|---|---|
| `code-reviewer` | correctness — logic, edge cases, error handling, concurrency, test adequacy |
| `security-reviewer` | what leaves the machine, what is stored, what is executed |
| `architecture-reviewer` | invariants A1–A7, and A3 in particular, which no grep can decide |
| `convention-reviewer` | every rule in `.claude/rules/` |
| `doc-gardener` | which docs the diff makes stale (proposes edits) |

Scale to the change: a docs-only edit may need only `doc-gardener`; anything touching the engine,
the Keychain, the OAuth flow or device handling runs the full panel. A finding you disagree with is
dismissed **on the record** — a sentence saying why — not silently.

"Done" = step 1 green, step 3 run for the affected area, step 5's findings all addressed or
dismissed on the record. Paste the tail of 1–3 and the findings into the PR.
