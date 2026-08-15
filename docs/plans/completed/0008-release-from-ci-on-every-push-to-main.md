# Plan 0008 — Release from CI on every push to main

- Status: **Built**
- Date: 2026-08-15
- Input: ADR-0018 (which this plan proposed), superseding the "produced locally" half of ADR-0017

## Goal

Today a release is a human at a keyboard running six numbered steps from
`docs/runbooks/release.md` §5, on one specific Mac, with a certificate in one specific login
keychain. When this is done, a merged PR is the whole release: pushing to `main` verifies the tree,
derives the next version from the commit subject, builds and notarizes the universal artefact,
publishes the GitHub release, and pushes the regenerated cask to `pmbrull/homebrew-tap` — with no
hand step and no second machine. The local lane stays exactly as it is, as the recovery path.

## Acceptance criteria

- [ ] `make verify` is green.
- [ ] `scripts/next-version.sh` passes its own table — every row of `scripts/check-next-version.sh`,
      including the three refusal rows (unparseable subject, unknown type, non-`X.Y.Z` current
      version). Wired into `make verify` as `make version-rule`, so the release rule cannot rot
      unnoticed.
- [ ] `make dist DIST_SIGN_ID=-` still builds a zip locally — the Makefile's `NOTARY_AUTH`
      indirection must not change what a local release does.
- [ ] `scripts/bump-version.sh` refuses to lower the version, and refuses a version that is not
      `X.Y.Z`.
- [ ] `.github/workflows/*.yml` parse (`pre-commit run check-yaml --all-files`).
- [ ] No credential appears in any file in this repo — the six secrets are named, never valued
      (invariant A4's spirit; the release lane's version of it).
- [ ] `docs/runbooks/release.md` describes the CI lane as the path and the local lane as the
      fallback, and lists the six secrets with where each comes from.
- [x] **Measured, not assumed:** the first CI release cuts a real version, notarytool Accepts it,
      `brew upgrade` moves an installed OnAir to it. **v0.2.0, 2026-08-15**, run `31894635012`:
      submission `15f8e1ed-be5c-42c9-b75a-820b07ce51a2` Accepted first try, `spctl` answers
      `Notarized Developer ID` on the CI-signed artefact, the tap's `sha256` matches the published
      asset byte-for-byte, and `brew upgrade --cask` moved an installed app `0.1.0 -> 0.2.0`. Written
      back into `docs/runbooks/release.md`, the same way v0.1.0's was.

## Affected modules

No Swift changes. Nothing under `Sources/`, so invariants A1–A6 are untouched by construction —
`make verify` proves that rather than this sentence.

| Path | Change |
|---|---|
| `.github/workflows/release.yml` | new — the lane |
| `.github/workflows/verify.yml` | gains `workflow_call:`; loses `push: branches: [main]` |
| `scripts/next-version.sh` | new — the bump rule, as a pure function of (version, commit message) |
| `scripts/check-next-version.sh` | new — its table test |
| `scripts/bump-version.sh` | new — writes both version keys into `Resources/Info.plist` |
| `scripts/publish-cask.sh` | new — pushes the rendered cask to the tap |
| `Makefile` | `NOTARY_AUTH` indirection; `version-rule` target added to `verify` |
| `docs/decisions/0018-*.md` | new; `0017` gains a supersession note |
| `docs/runbooks/release.md` | §5 becomes the CI lane; the manual lane becomes §6 |
| `CLAUDE.md`, `docs/index.md` | pointers |

## Steps

1. **The rule, in isolation.** `scripts/next-version.sh <current> <message-file|->` prints the next
   version, or exits 3 ("this commit releases nothing") or 1 ("cannot decide"). Distinct exit codes
   so the workflow branches on a number rather than on matched text.
2. **Its table.** `scripts/check-next-version.sh`, wired to `make version-rule` and into `verify`.
   Written before step 1 is trusted.
3. **The plist writer.** `scripts/bump-version.sh <version>` — sets `CFBundleShortVersionString`,
   increments `CFBundleVersion`, `plutil -lint`s the result, refuses a downgrade.
4. **`verify.yml` becomes callable.** Add `workflow_call:`, drop `push: branches: [main]` (the
   release workflow now runs it on every push to main, so keeping both would double the build).
5. **The workflow.** `release.yml`: `gate` (calls `verify.yml`) and `decide` in parallel, then
   `release` gated on both. `release` bumps the plist *in the working tree only*, builds, signs
   and notarizes, and only then commits, tags, publishes and pushes the cask.
6. **The tap push.** `scripts/publish-cask.sh` — clones the tap, writes `Casks/onair.rb`, commits
   `onair <version>`, pushes. No-ops when the rendered cask is byte-identical to what is there.
7. **Docs.** ADR-0018, the supersession note on ADR-0017, the runbook rewrite, the index entries.
8. **Verify and open the PR.** `make verify`, then the review subagents, then `open-pr`.

## Risks

| Risk | What catches it early |
|---|---|
| **The workflow re-triggers itself** — its own bump commit is a push to `main`. | Two independent guards: pushes authenticated with `GITHUB_TOKEN` do not trigger workflows, *and* the commit subject carries `[skip ci]`. Belt and braces because a loop here notarizes in a circle. |
| **A half-finished release**: notarization succeeds, the tap push fails. | Ordering. Everything that mutates `main`, the tags, the releases or the tap happens *after* `notarize` returns. A failure before that point leaves no trace anywhere. A failure after it leaves the runbook's manual recovery path, which is the old §5 — kept, not deleted, for exactly this. |
| **The signing key leaks.** | It is a `.p12` in an ephemeral keychain in `$RUNNER_TEMP`, deleted in an `if: always()` step, on a single-tenant VM that is destroyed. It is revocable at developer.apple.com. That is the residual risk ADR-0018 accepts out loud rather than the one it pretends away. |
| **A version is skipped** because a build failed after the plist was bumped. | The bump is not committed until notarization has passed, so a failed build leaves the plist alone. |
| **`decide` and the plist disagree** about the current version. | One reader: `PlistBuddy`, which is why `decide` runs on `macos-15` for a two-second job instead of re-parsing the plist with Python on a Linux runner. Two readers is how the version drifts. |
| **Unparseable commit subject silently ships a patch.** | It does not — exit 1, job red. `.claude/rules/no-silent-fallbacks.md`, applied to the release lane. |
| **CI promotes the project to `1.0.0`** on a stray `feat!:`. | While the major is `0`, a breaking change bumps the *minor*. `1.0.0` is only reachable through `workflow_dispatch` with an explicit version — a human act. |
| **Concurrent pushes to `main`** race on the bump commit. | `concurrency: release-main`, `cancel-in-progress: false` (cancelling between `notarytool` and the tap push is the one thing worse than queueing). A push rejected because a human moved `main` fails the job loudly. |

## Decision log

- 2026-08-15 — The Developer ID key goes into GitHub secrets, reversing ADR-0017's rejection — the
  ask is a release on every push to `main`, and the hybrid (CI tags, human runs `make release`)
  cannot deliver it: every version would still need one specific laptop. Recorded as ADR-0018 with
  the accepted risk stated, not as a plan-level footnote.
- 2026-08-15 — Notarization authenticates with an **App Store Connect API key**, not the Apple ID
  app-specific password the local lane uses. The key is independently revocable, scoped to
  notarization, and keeps the maintainer's Apple ID out of CI entirely. The local lane keeps its
  keychain profile — hence one `NOTARY_AUTH` variable rather than a second `notarize` target.
- 2026-08-15 — The cask is **pushed** to the tap, not opened as a PR there. A PR in a
  one-maintainer repo full of generated output is a queue of one that nobody reviews, and while it
  sits, `brew` serves the old version — which is precisely the consequence ADR-0017 recorded
  ("forgetting to update it strands users on the old version"). The human gate is upstream: the PR
  merge into `main` that started the release.
- 2026-08-15 — `verify.yml` loses its `push: branches: [main]` trigger rather than gaining a
  sibling. `release.yml` calls it as a reusable workflow, so keeping the trigger would run the
  whole macOS build twice per push for one signal.
- 2026-08-15 — The bump rule lives in a shell script with a table test, not inline in the YAML.
  It decides *whether and what* gets released; inline YAML is where decisions go to become
  untestable. Same instinct as invariant A3, one layer out.
- 2026-08-15 — **Found by the table, not by review:** `feat:` followed only by spaces passed as a
  minor bump, because `.+` matches whitespace. A truncated subject was inferring an intent it never
  stated. The description now has to contain a non-space character.
- 2026-08-15 — Replayed the rule over all seven commits in this history rather than trusting the
  table alone: 4 release, 1 skips, and **2 fail** (`56b5a66` "Render the emoji…", `b9ffb25` "Initial
  commit"). Written into CLAUDE.md, because "two commits in your own history would fail this" is the
  sentence that makes the convention real.
- 2026-08-15 — `${{ github.ref }}` was being expanded into a shell `echo`, and `workflow_dispatch`
  can run on any ref — so a branch name would have been executed. Both templates in `run:` blocks
  became `$GITHUB_REF` / `$GITHUB_REPOSITORY`, and a check that no `${{ }}` survives in any `run:`
  block is part of the verification.
- 2026-08-15 — `git commit -am` became `git commit -- Resources/Info.plist`. The release commit is
  allowed to carry exactly one file; anything a build step happened to write into a tracked path
  would otherwise ride along invisibly.
- 2026-08-15 — Added three tries around `make-cask.sh`. A release asset is not always downloadable
  the instant `gh release create` returns, and hashing the *published* asset is the whole reason
  that step exists — losing it to a few seconds of eventual consistency would strand users on the
  old cask for the one reason the design was meant to rule out.
- 2026-08-15 — This PR is titled `ci:` deliberately, so merging it does **not** fire a release
  before the six secrets exist. The first release is a `workflow_dispatch` with an explicit version,
  chosen rather than triggered.
- 2026-08-15 — **Setup found three traps, none of them in the code.** The repo had all three GitHub
  merge defaults that break "the PR title decides the version" (`COMMIT_OR_PR_TITLE`, merge commits,
  rebase merges) — ADR-0018 had assumed a merge shape nobody had configured. Keychain Access exports
  a `.p12` with an empty passphrase without complaint, which reads as "secret never set". And setting
  the passphrase secret from `pbpaste` lost to whatever was copied next, which is what actually broke
  the first release attempt. All three are now runbook steps or troubleshooting rows; two of them are
  the kind of thing only a real run surfaces.
- 2026-08-15 — **v0.2.0 shipped through Actions** (run `31894635012`, 2m40s), and the run before it
  failed at the certificate import — which measured the ordering property for free: no tag, no
  release, no plist bump, no cask change after a failed release. The plan's central safety claim was
  tested by something going wrong, which is better evidence than the green run.
- 2026-08-15 — The `security import` failure reported only
  `SecKeychainItemImport: ... not correct.` and `exit code 1`, naming neither secret nor the fix. It
  now emits a titled annotation. A lane a human only visits when it breaks should say the useful
  thing at the moment it breaks.
