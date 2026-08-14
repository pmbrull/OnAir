# Plan 0005 — Release through a personal Homebrew tap

- Status: Active
- Date: 2026-08-14
- Input: README TODO ("get this installable"), ADR-0012 (the shared app already exists), runbook
  `shared-app.md` (the Slack side is done once, ever — this is the artefact side).

## Goal

A person who has never seen this repo can run `brew install --cask pmbrull/tap/onair` and get a
signed, notarized OnAir.app with an icon, and the maintainer can produce each release with one
documented command sequence from this machine. Today none of that exists: the bundle has no icon,
`make app` signs for local use only (no hardened runtime, no timestamp), nothing zips or
checksums an artefact, and no cask or tap exists.

## Acceptance criteria

- [ ] `make verify` is green.
- [ ] `make app` produces a bundle whose `Info.plist` names an icon and whose `Resources/`
      contains `AppIcon.icns`; `plutil -lint` passes; the existing A5 bundle check still passes
      (no usage-description keys appear).
- [ ] `scripts/make-icon.sh` regenerates `Resources/AppIcon.icns` deterministically from code —
      no design tool, no binary source of truth besides the committed icns; `iconutil` accepts
      the iconset both directions.
- [ ] `make dist DIST_SIGN_ID=-` (ad-hoc override, for machines without the certificate) produces
      `.build/dist/OnAir-<version>.zip` plus a `.sha256`, with the version read from
      `Resources/Info.plist` — one source of truth, same as `BUNDLE_ID`.
- [ ] `make dist` with no override **fails loudly** when no Developer ID Application identity is
      in the keychain — it must never fall back to ad-hoc silently
      (`.claude/rules/no-silent-fallbacks.md`).
- [ ] The dist bundle is signed with hardened runtime + secure timestamp and carries no
      entitlements (OnAir needs none: no JIT, no capture, not sandboxed).
- [ ] `scripts/make-cask.sh` emits a complete cask (version + sha256 filled from the artefact)
      ready to drop into a `homebrew-tap` repo.
- [ ] `docs/runbooks/release.md` walks the maintainer from "no certificate in the keychain"
      (measured: this machine has zero codesigning identities today) to a published release and
      an updated tap, including the one-time Apple Developer steps and the Slack-side checklist.
- [ ] README's Install section leads with brew and no longer clones `SlackStatus.git` (stale repo
      name).
- [ ] ADR records the distribution choice (personal tap + notarized zip, released locally) and
      the alternatives it beat.

## Affected modules

- `Resources/` (Info.plist keys, new AppIcon.icns) — no invariant touched; the CI bundle check
  guards A5 in the artefact.
- `Makefile`, `scripts/` — build/packaging only.
- `docs/` — runbook, ADR, README, index.
- **No `Sources/` change.** A1–A5 untouched; nothing new executes at runtime.

## Steps

1. **ADR-0016**: distribute through a personal tap as a notarized zip, released from this machine.
2. **Icon**: `scripts/make-icon.sh` drives a small Swift renderer (AppKit, build-host only — not a
   target, so A2 is not in play) that draws the ON AIR sign onto the macOS icon grid at every
   required size, then `iconutil` packs `AppIcon.icns`. Commit the icns; reference it from
   `Info.plist` (`CFBundleIconFile`); copy it in `make app`.
3. **Info.plist**: add `CFBundleIconFile`, `NSHumanReadableCopyright`,
   `LSApplicationCategoryType`.
4. **Makefile release lane**: `build` honours `CONFIG` (default unchanged); `dist` = release
   build → bundle → Developer ID sign (hardened runtime, timestamp, no `--deep`) → `ditto` zip →
   sha256; `notarize` = `notarytool submit --wait` → `stapler staple` → re-zip → re-checksum;
   `release` = both plus a `spctl --assess` verdict. Version read from the plist.
5. **Cask**: `scripts/make-cask.sh` renders `onair.rb` from the dist artefact.
6. **Docs**: `docs/runbooks/release.md` (the guide), `docs/index.md` row, README install section,
   CLAUDE.md command table.
7. **Verify**: `make verify`, `make app`, `make dist DIST_SIGN_ID=-`, `make run` (the app still
   behaves; the icon shows in Finder).

## Risks

- **A universal (arm64 + x86_64) build may not link on a CLT-only machine.** Try
  `--arch arm64 --arch x86_64`; if CLT refuses, ship arm64-only and say so in the cask
  (`depends_on arch: :arm64`) and the decision log. Do not guess — measure.
- **Notarization cannot be exercised in this change**: it needs an Apple Developer certificate
  and a notary profile that do not exist on this machine yet. The runbook marks the first real
  release as the measurement point; the make lane is built so every step before `notarize` is
  testable today.
- **Signature change vs the existing Keychain item**: a dev-signed build wrote the token; a
  Developer-ID-signed build reading it will trigger one macOS Keychain consent prompt. Documented
  in the runbook so it is not mistaken for a bug.
- **`iconutil`/`sips` availability**: both are system binaries, present without Xcode — verified
  on this machine before writing the script.

## Decision log

- 2026-08-14 — Local release lane, not CI signing — the certificate lives on this machine;
  importing it into GitHub Actions secrets adds a leak surface and an untestable-until-tagged
  workflow. Revisit if a second maintainer appears. Recorded in ADR-0016.
- 2026-08-14 — Personal tap first, `homebrew/cask` later — the official repo gates on
  project notability (stars/forks thresholds a new repo cannot meet); a personal tap has no gate
  and the cask moves over unchanged if the project ever qualifies.
- 2026-08-14 — Measured before planning: `notarytool` and `stapler` ARE in this machine's CLT
  (`/Library/Developer/CommandLineTools/usr/bin/`), so no Xcode install is needed for a local
  release; `security find-identity -v -p codesigning` returns zero identities, so the runbook
  starts at certificate creation.
- 2026-08-14 — Universal binary: `--arch arm64 --arch x86_64` fails on CLT ("xcbuild executable
  ... does not exist" — XCBuild ships with Xcode), but two `--triple` builds plus `lipo -create`
  work. `make dist` does the latter; `lipo -archs` on the artefact reports `x86_64 arm64`.
- 2026-08-14 — Review round (five read-only reviewers on the staged diff). Applied: the notary
  password moved off the command line (interactive prompt instead — it was landing in shell
  history); X.Y.Z-only guards on the plist version in both `make dist` and `make-cask.sh` (the
  value is substituted into shell and into Ruby brew executes on users' machines); `make-cask.sh`
  now hashes the **published** release asset rather than the local zip, so the cask sha cannot
  drift from what users download; `spctl --assess` moved before the re-zip so a failed verdict
  leaves no publishable-looking artefact; `$(filter -,…)` → `$(subst)` for the ad-hoc timestamp
  test (word-list match would hit a "-" token inside a real identity name); `.NOTPARALLEL:`;
  loud `fatalError` on nil drawing context and missing SF Rounded in the icon renderer; ADR-0016
  status header; CI now asserts the icon in the assembled bundle; `check-references.sh` scans the
  Makefile; doc-gardener's staleness list (dev-loop, ARCHITECTURE, first-run, profile, README
  count, CLAUDE.md state) applied in full.
- 2026-08-14 — Dismissed on the record: (a) a verify-time provenance check tying the committed
  icns to the script — font rasterization is not byte-stable across macOS versions, so equality
  is unenforceable; at TEAM = 1 the icns changes only via `make icon` and the PR diff shows it;
  (b) `head -1` picking the first of several Developer ID identities — `dist` prints the chosen
  identity loudly, and a multi-identity keychain is a maintainer-visible state.
- 2026-08-14 — `make doctor` from this agent shell prints the full device inventory only under a
  pseudo-tty (block-buffered stdout otherwise), then parks on the Slack section's Keychain read:
  every rebuild of the ad-hoc-signed binary is a new code hash, so macOS raises a consent dialog
  a non-interactive shell cannot answer. Devices verified live (camera idle, Yeti + built-in mic
  `in use` — ADR-0011's exact story); the stall is the same signature-change consent the release
  runbook documents for the dev-build → Developer-ID upgrade. Not a regression; no `Sources/`
  file changed in this plan.
