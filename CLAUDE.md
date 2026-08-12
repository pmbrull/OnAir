# CLAUDE.md

Guidance for Claude Code working in this repository. The daily table of contents.

## What this is

OnAir is a macOS menu-bar app. When your camera turns on, it sets your Slack status; when it turns
off, it puts the old one back. It never opens the camera to find out — it asks macOS whether one is
running — so it needs no camera permission and never appears in Privacy & Security.

## Read first

| Doc | When |
|---|---|
| [`docs/agent-workflow.md`](docs/agent-workflow.md) | **Before any change.** The loop, and the harness-gap valve. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Before touching module boundaries. Invariants A1–A5. |
| [`docs/dev-loop.md`](docs/dev-loop.md) | How to build, run and exercise it — including the XCTest quirk. |
| [`docs/index.md`](docs/index.md) | The map of everything else. |
| [`.claude/rules/`](.claude/rules/) | The four conventions a reviewer will hold you to. |

## The loop, in one line

`plan-feature` → implement → `verify-change` → review subagents → `open-pr`. Same step fails twice
for the *same reason* → `harness-gap`, and the harness fix becomes the work.

## Commands

```bash
make verify        # the gate: references + arch + fmt-check + lint + build + test
make doctor        # everything the app does, minus the window — against real hardware
make doctor-slack  # as doctor, plus one read-only Slack round trip
make test          # the suite (see below — not `swift test`)
make app           # assemble .build/OnAir.app
make run           # build and launch
make uninstall     # remove the app, its Keychain items and its support directory
```

## The five things most likely to trip you up

1. **`swift test` does not work here; `make test` does.** XCTest ships with Xcode, not the Command
   Line Tools, so the suite is written against Swift Testing — which CLT ships on no default search
   or runtime path. `make test` detects that and adds a framework path and two rpaths. Same for
   `swift build --build-tests`.
2. **Slack refuses `http://` redirect URLs, with no localhost exception.** That single fact is why
   there is a TLS listener, a self-signed certificate and a call to `/usr/bin/openssl` in this
   codebase (ADR-0005). Do not "simplify" it back to plain HTTP; it will not register.
3. **A running microphone does not mean a meeting.** Audio mixers hold inputs open around the
   clock — measured, on this machine, via Elgato Wave Link. Hence `watchMicrophone: false` by
   default (ADR-0011). Before changing any device default, run `make doctor`.
4. **A refresh must not re-read the live status.** When the emoji or text is edited mid-call, OnAir
   re-applies — and if it re-read the profile to find `previous`, it would stash its *own* status
   and the eventual restore would be a no-op that strands it (ADR-0008). `engine.appliedPrevious`
   is what distinguishes the two paths.
5. **The engine must be told what happened.** `advance` returns an intent; until the caller reports
   back with `recordApplied` / `recordSkipped` / `recordRestored` / `recordFailed`, the engine
   assumes nothing happened and offers the same intent again. That is the retry, and it is why a
   failure path that silently advances the state machine strands a status.

## Hard rules

- **Never open a capture stream.** Read `IsRunningSomewhere`; nothing else. Invariant A5, ADR-0001.
- **Never put a credential anywhere but the Keychain** — not `UserDefaults`, not a log, not an
  interpolated string. Invariant A4, ADR-0006.
- **Never compile in a client secret.** The user's Slack app, the user's secret (ADR-0005).
- **Never overwrite a status OnAir did not set**, unless the user asked for it (ADR-0008).
- **Never import AppKit/SwiftUI/ServiceManagement into a kit** (ADR-0002). Invariant A2.
- **Never put a decision in the app target.** If it changes *whether* something happens, it belongs
  in `StatusKit`, where it can be tested. Invariant A3.
- **Never fill an unknown with a plausible value.** Report it as unknown
  (`.claude/rules/no-silent-fallbacks.md`).
- **Never self-merge.** An agent opens the PR; a human merges.
- **Don't guess — open a gap.** [`docs/gaps/README.md`](docs/gaps/README.md).

## Current state

v0.1. Everything described above is built and the gate is green: 68 tests in 8 suites, including a
device journey against this Mac's real hardware and a loopback suite that mints a real certificate
and drives a real TLS listener with `URLSession`.

What is **not** verified against reality is Slack's JSON: the fixtures in
`Tests/SlackKitTests/SlackResponseFixtures.swift` were written from Slack's documentation because
no workspace was available, and they are marked as such (GAP-0001). The end-to-end connect flow has
not been run against a live workspace either — `make doctor-slack` is the command that will, and it
is read-only.

The one measured surprise so far is ADR-0011: the microphone reads *in use* permanently on a Mac
running an audio mixer, which turned a planned default of "watch both" into "watch the camera, and
tell the user how to check whether the microphone is safe on their machine".
