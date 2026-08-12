# Plan 0001 — Camera-driven Slack status

- Status: Active
- Date: 2026-08-12
- Input: the initial brief — "a native macOS app that checks if my camera is on, and if so, updates
  my Slack status; config for icon + status, connect to Slack, overriding Slack status yes/no"

## Goal

A menu-bar app that watches this Mac's capture devices, sets a configurable Slack status while one
is in use, and puts the previous status back afterwards — connected through a real OAuth browser
flow, with the token in the Keychain and no permission prompt of any kind. Plus the working
agreement that goes with it: the gate, the docs tree, the reviewers and the rules, ported from
`scholia` and retargeted.

## Acceptance criteria

- [x] `make verify` is green.
- [x] OnAir needs **no** camera or microphone permission, verified by running `doctor` on an
      unsigned build with no TCC entry, and enforced by a build check (A5).
- [x] The Slack token exists only in the Keychain, enforced by a build check (A4).
- [x] The debounce, the pause, the override rule and the ownership test are pure functions in
      `StatusKit` with tests — no decision in the app target (A3).
- [x] `make doctor` reports this Mac's real devices and what the engine would do.
- [x] `DeviceJourneyTests` runs against real hardware, asserts per device, and disables itself
      where there is none.
- [x] `LoopbackTests` mints a real certificate and drives a real TLS listener end to end.
- [ ] The connect flow is run against a live Slack workspace and the fixtures replaced with
      captured output (GAP-0001).

## Affected modules

New: `DeviceKit`, `StatusKit`, `SlackKit`, `OnAir`. Every invariant A1–A5 is introduced by this
plan rather than touched by it.

## Steps

1. [x] Harness: `Makefile`, `scripts/check-{references,architecture}.sh`, pre-commit, CI,
       swiftformat/swiftlint config.
2. [x] `DeviceKit` — CoreMediaIO + CoreAudio property listeners, hot-plug re-attachment,
       `DeviceWatcher`.
3. [x] `StatusKit` — `UserStatus`, `StatusPolicy`, `StatusEngine`, `OverwriteVerdict`.
4. [x] `SlackKit` — `SlackWire`, `SlackClient`, `LoopbackIdentity`, `LoopbackReceiver`,
       `SlackOAuth`.
5. [x] `OnAir` — `TokenStore`, `PolicyStore`, `LaunchAtLogin`, `AppCoordinator`, menu bar,
       Settings, `Doctor`.
6. [x] Tests: 68 across 8 suites.
7. [x] Docs: 11 ADRs, GAP-0001, profile, agent-workflow, dev-loop, first-run runbook, 4 skills,
       5 reviewers, 4 rules.
8. [ ] Live-workspace verification (blocked on a Slack app existing).

## Risks

- **Slack's redirect rules.** Checked before designing: HTTPS is mandatory, no localhost exception.
  Caught at plan time rather than at implementation time.
- **Certificate minting on an unknown LibreSSL.** Verified end to end on this machine before any
  code depended on it (LibreSSL 3.3.6: SAN correct, `SecPKCS12Import` returns 0).
- **A microphone signal that is not a meeting signal.** Realised, and it is the largest single
  finding in this plan — see the decision log.
- **The parser matching a Slack we have never seen.** Unmitigated; GAP-0001 records it rather than
  letting the green suite imply coverage it lacks.

## Decision log

- 2026-08-12 — Copy `scholia`'s harness wholesale, retarget the invariants — the shape (gate,
  ADRs, gaps, plans, read-only reviewers, rules) is project-independent; only A1–A5 and the
  real-data rule needed rewriting for this domain.
- 2026-08-12 — Verified Slack's redirect rules before designing auth. Slack requires HTTPS with no
  localhost exception, which invalidated the "http loopback" assumption in the brief. Presented
  three shapes; chose the self-signed HTTPS loopback so the authorisation code never leaves the
  machine (ADR-0005).
- 2026-08-12 — Ship no client secret. The user creates the Slack app anyway, so both halves go into
  the Keychain and the binary stays secret-free.
- 2026-08-12 — Proved the openssl → `SecPKCS12Import` path by hand before writing
  `LoopbackIdentity`, because it was the riskiest unknown in the plan and a late failure there
  would have invalidated the auth design.
- 2026-08-12 — Moved the override rule and the ownership test out of `AppCoordinator` into
  `StatusKit` as `verdict(forLive:)` and `stillOwns(_:)`. They started as `if`s in the coordinator,
  where the app target's lack of tests would have left the two rules the user cares about most
  entirely unverified. This is what A3 is for.
- 2026-08-12 — XCTest is unavailable: this machine has Command Line Tools and no Xcode. Rewrote the
  suite against Swift Testing and taught `make test` to supply the framework path and two rpaths,
  detecting which toolchain is present. Three attempts, each narrowing the diagnosis — not a
  harness gap, because it was converging rather than stuck.
- 2026-08-12 — **`watchMicrophone` defaults to `false`.** `make doctor` on real hardware showed the
  Yeti and the built-in microphone reading *in use* permanently, with no call running; `pgrep`
  found Elgato Wave Link holding both open in the background. The planned default would have
  pinned this user's status on forever. The capability is unchanged and one toggle away
  (ADR-0011). No unit test could have found this, which is the entire argument for the real-data
  rule.
- 2026-08-12 — Stale test binary reported "59 tests passed" while the new target had failed to
  compile. Only noticed by checking the suite count against the files. Worth remembering: with
  Swift Testing, a green run whose *count did not change* after adding tests is a compile failure,
  not a pass.
