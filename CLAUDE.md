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
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Before touching module boundaries. Invariants A1–A6. |
| [`docs/dev-loop.md`](docs/dev-loop.md) | How to build, run and exercise it — including the XCTest quirk. |
| [`docs/index.md`](docs/index.md) | The map of everything else. |
| [`.claude/rules/`](.claude/rules/) | The four conventions a reviewer will hold you to. |

## The loop, in one line

`plan-feature` → implement → `verify-change` → review subagents → `open-pr`. Same step fails twice
for the *same reason* → `harness-gap`, and the harness fix becomes the work.

## Commands

```bash
make verify         # the gate: references + arch + fmt-check + lint + build + test
make doctor         # everything the app does, minus the window — against real hardware
make doctor-slack   # as doctor, plus one read-only Slack round trip
make test           # the suite (see below — not `swift test`)
make app            # assemble .build/OnAir.app
make run            # build and launch
make icon           # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
make release        # dist (signed universal zip) + notarize — docs/runbooks/release.md
make uninstall      # remove the app, its Keychain items and its support directory
make purge-loopback # list loopback keys stranded in the login keychain before ADR-0016
```

## The six things most likely to trip you up

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
5. **`SecPKCS12Import` writes to the login keychain unless you stop it.** The obvious call — pass
   the passphrase, take the `SecIdentity` — permanently deposits the certificate *and its private
   key* in the user's login keychain, once per distinct archive. Each key's ACL names the importing
   binary, so a rebuilt OnAir makes macOS ask the human for their login password. 268 stranded keys
   on the machine that found it, most of them minted by `make verify` itself. `kSecImportToMemoryOnly`
   is the whole fix; invariant A6 fails the build without it (ADR-0016).
6. **The engine must be told what happened.** `advance` returns an intent; until the caller reports
   back with `recordApplied` / `recordSkipped` / `recordRestored` / `recordFailed`, the engine
   assumes nothing happened and offers the same intent again. That is the retry, and it is why a
   failure path that silently advances the state machine strands a status.

## Hard rules

- **Never open a capture stream.** Read `IsRunningSomewhere`; nothing else. Invariant A5, ADR-0001.
- **Never put a credential anywhere but the Keychain** — not `UserDefaults`, not a log, not an
  interpolated string. Invariant A4, ADR-0006.
- **Never put the loopback key *in* a keychain.** `SecPKCS12Import` must pass
  `kSecImportToMemoryOnly`. Invariant A6, ADR-0016.
- **Never reintroduce a client secret.** OnAir is a public client: PKCE proves the connection,
  and the only shipped identifier is the public client id (ADR-0012). A `client_secret` appearing
  anywhere — code, Settings, Keychain — is a regression, not an option.
- **Never overwrite a status OnAir did not set**, unless the user asked for it (ADR-0008).
- **Never restore a status without the expiry it arrived with** (ADR-0015). Google Calendar and
  friends set `status_expiration` and never come back; putting the words back without the clock
  strands the status forever. A passed expiry restores as a *clear*, not as the old words.
- **Never import AppKit/SwiftUI/ServiceManagement into a kit** (ADR-0002). Invariant A2.
- **Never put a decision in the app target.** If it changes *whether* something happens, it belongs
  in `StatusKit`, where it can be tested. Invariant A3.
- **Never fill an unknown with a plausible value.** Report it as unknown
  (`.claude/rules/no-silent-fallbacks.md`).
- **Never self-merge.** An agent opens the PR; a human merges.
- **Don't guess — open a gap.** [`docs/gaps/README.md`](docs/gaps/README.md).

## Current state

v0.1. Everything described above is built and the gate is green: 115 tests in 13 suites, including a
device journey against this Mac's real hardware and a loopback suite that mints a real certificate
and drives a real TLS listener with `URLSession`.

What is **partly** verified against reality is Slack's side of the wire. One live
`users.profile.get` (2026-08-13, `make doctor-slack` against Collate) parsed cleanly, which pins
`status_emoji`, `status_text` and `status_expiration` on the with-a-status shape — and a stored
token answering at all means `oauth.v2.access` accepted the PKCE exchange, since `TokenStore` is
written from exactly one place. Still unmeasured: the fixtures are prose rather than captures
(GAP-0001), the empty-status and error shapes are untouched, and token longevity needs thirty days
or an `expires_in` in a captured exchange (GAP-0002). `make doctor-slack` is the read-only live
check.

The release lane (ADR-0017) is built and exercised up to Apple's door — `make dist DIST_SIGN_ID=-`
runs everything short of the notary — but no release has been cut: the keychain holds no Developer
ID certificate yet, so notarization, the tap and `brew install` are unmeasured until v0.1.0 ships.
`docs/runbooks/release.md` pins that first release as the measurement point; until then the
README's brew line is the destination, not the reality.

Two things reality has corrected so far, and both were seen rather than reasoned. **ADR-0011**: the
microphone reads *in use* permanently on a Mac running an audio mixer, which turned a planned
default of "watch both" into "watch the camera, and tell the user how to check whether the
microphone is safe on their machine". **ADR-0015**: a status restored from a calendar integration
was stranded forever, because the integration writes `status_expiration` and never comes back —
restoring the words without the clock removes the only thing that was going to clear it.
