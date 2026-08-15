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
make verify         # the gate: references + arch + version-rule + fmt-check + lint + build + test
make doctor         # everything the app does, minus the window — against real hardware
make doctor-slack   # as doctor, plus one read-only Slack round trip
make test           # the suite (see below — not `swift test`)
make app            # assemble .build/OnAir.app
make run            # build and launch
make icon           # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
make version-rule   # the release bump rule's table — what your commit subject would ship
make release        # dist + notarize LOCALLY — the recovery lane; CI releases (ADR-0018)
make uninstall      # remove the app, its Keychain items and its support directory
make purge-loopback # list loopback keys stranded in the login keychain before ADR-0016
```

**Releasing is merging.** Every push to `main` runs `.github/workflows/release.yml`: gate, derive the
version from the commit subject, build, sign, notarize, tag, publish, push the cask to the tap
(ADR-0018, `docs/runbooks/release.md`). Nothing outside the runner is touched until notarization has
passed, so a failed build leaves no bumped version and no orphan tag.

## The seven things most likely to trip you up

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
7. **The PR title decides the released version** — squash-merged, with
   `squash_merge_commit_title=PR_TITLE` set on the repo (runbook §4; GitHub's default would use your
   commit subject instead on a one-commit PR). It becomes the squashed commit subject, and
   `scripts/next-version.sh` reads it: `feat:` ships a minor, `fix:`/`perf:`/`revert:` a patch,
   `docs:`/`chore:`/`ci:`/`test:`/`refactor:`/`style:`/`build:` ship nothing at all. A subject that is
   not a Conventional Commit **fails the release job** rather than defaulting to a patch (ADR-0018).
   `make version-rule` is the table; two commits already in this history would fail it.

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

The release lane (ADR-0017) has now run for real. **v0.1.0 shipped 2026-08-14**: notarytool
Accepted the bundle first try, `spctl` answers `Notarized Developer ID` on the brew-installed app,
and `brew install --cask pmbrull/tap/onair` works from a clean tap. The README's brew line is the
reality, not the destination. What the release measured — and the two things it still did not — is
in `docs/runbooks/release.md`.

That lane has since moved into CI (**ADR-0018**): a push to `main` releases, and `make release` is
the recovery path. What is measured today is the bump rule (37 cases) and the fact that the build
targets are the same ones v0.1.0 shipped with. What is **not** measured is the CI lane end to end —
the keychain import, the App Store Connect notary key and the tap push are first exercised by the
first release that runs through Actions, and that release's result belongs in
`docs/runbooks/release.md` next to v0.1.0's. Two commits already in this history
(`56b5a66`, `b9ffb25`) would fail the version rule, which is the intended behaviour and worth
knowing before writing a PR title.

Three things reality has corrected so far, and all three were seen rather than reasoned.
**ADR-0011**: the
microphone reads *in use* permanently on a Mac running an audio mixer, which turned a planned
default of "watch both" into "watch the camera, and tell the user how to check whether the
microphone is safe on their machine". **ADR-0015**: a status restored from a calendar integration
was stranded forever, because the integration writes `status_expiration` and never comes back —
restoring the words without the clock removes the only thing that was going to clear it. And the
cask's `depends_on macos: ">= :sequoia"` was deprecated the whole time — nothing in this repo could
say so, because only a real `brew install` runs Homebrew's parser over it.
