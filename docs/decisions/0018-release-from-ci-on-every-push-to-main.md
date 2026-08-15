# ADR-0018 — Release from CI on every push to main, with the signing key in repository secrets

- Status: Accepted
- Date: 2026-08-15
- Supersedes: the "produced locally" half of [ADR-0017](0017-distribute-through-a-personal-tap.md).
  The channel that ADR chose — a personal tap, a notarized stapled zip, no DMG, no Sparkle — stands
  unchanged. Only *who runs the lane* changes.

## Context

ADR-0017 weighed CI signing against local signing and chose local, on one argument: "a key that can
sign as the maintainer does not belong in repository secrets while one laptop is the whole team." It
also wrote down the cost it was accepting — "releases are single-homed on the maintainer's machine
and keychain… nobody else can cut a release until the CI question is reopened."

The question is now reopened, and one release of experience has changed what the two sides weigh.

What the local lane actually costs, measured on v0.1.0:

- Six numbered manual steps, two of which (`gh release create`, the cask paste) are pure
  bookkeeping that a script does better than a human at the end of a long day.
- A second repository to remember. ADR-0017 predicted the failure mode — "forgetting to update it
  strands users on the old version" — and mitigated it with a generator whose output you still have
  to paste somewhere.
- The version lives in `Resources/Info.plist` and is bumped by hand, so "which version is this" and
  "was it released" are two facts that can disagree.

What has *not* changed: TEAM = 1, and the key can still sign arbitrary code as the maintainer.

Two things narrow that risk relative to how ADR-0017 framed it:

- **Notarization has its own credential.** An App Store Connect API key (`.p8` + key id + issuer
  id) is scoped to the notary service and revocable on its own, so CI never needs the Apple ID or
  an app-specific password that unlocks the whole account. ADR-0017 did not distinguish these; it
  reasoned about "the key" as one thing.
- **The certificate is revocable and re-issuable in minutes.** Compromise means "revoke, re-issue,
  re-release", not "lose the ability to ship". ADR-0017 already established this for the
  lost-laptop case; it applies identically here.

What is genuinely worse in CI, and is not talked away: a GitHub account or Actions compromise
becomes a code-signing compromise. On the local lane it is not.

## Decision

- **Every push to `main` runs the release lane**, in `.github/workflows/release.yml`. A merged PR is
  the release; there is no hand step.
- **The Developer ID `.p12` and its passphrase live in GitHub Actions secrets**, imported into an
  ephemeral keychain under `$RUNNER_TEMP` that is deleted in an `if: always()` step. Six secrets,
  no more: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_API_KEY_P8`,
  `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID`, `HOMEBREW_TAP_TOKEN`.
- **Notarization authenticates with an App Store Connect API key**, not with the Apple ID
  app-specific password the local lane uses. The Makefile gains one `NOTARY_AUTH` variable so both
  forms drive the same target; the local default is unchanged.
- **The version is derived, not typed.** `scripts/next-version.sh` maps the squashed commit subject
  to a bump: `feat:` → minor, `fix:`/`perf:`/`revert:` → patch, `docs:`/`chore:`/`ci:`/`test:`/
  `refactor:`/`style:`/`build:` → no release at all. A breaking change bumps the **minor** while the
  major is `0`; `1.0.0` is reachable only through `workflow_dispatch` with an explicit version,
  because a version number that declares stability is a human's claim to make.
- **An undecidable subject fails the job.** A commit message that is not conventional, or is
  conventional with an unknown type, exits non-zero rather than defaulting to a patch bump.
  `.claude/rules/no-silent-fallbacks.md` in the release lane: "never invent a value to fill a hole"
  includes version numbers.
- **Nothing outside the runner is touched until notarization has passed.** The plist bump happens in
  the working tree; the commit, the tag, the GitHub release and the tap push all happen after
  `notarytool` and `spctl` have returned. A failed build leaves no bumped version, no orphan tag and
  no half-updated tap.
- **The cask is pushed to the tap, not proposed to it.** `scripts/publish-cask.sh` commits
  `Casks/onair.rb` directly. The human gate is the PR merge that started the release.
- **The local lane is kept, documented, and demoted to the recovery path.** `make release` and the
  old runbook steps are what you run when CI dies mid-release, or when Actions is down, or when the
  release must be cut from a machine.

## Consequences

- A release costs one PR merge. The version, the tag, the release notes, the notarized artefact and
  the tap all follow from it, and cannot disagree with each other.
- **A GitHub compromise is now a signing compromise.** This is the price, stated plainly. The
  mitigations are the ephemeral keychain, the separately-revocable notary key, and the fact that
  `main` is where releases come from — so branch protection on `main` is now a code-signing control,
  not just a code-review one. Enabling it is follow-up work this ADR names and does not do.
- Commit subjects become load-bearing. `56b5a66` ("Render the emoji, invert the pause switch…")
  would fail the release job today. That is the intended behaviour, and it makes the conventional
  prefix a real convention rather than a habit.
- A `docs:`-only push releases nothing, so documentation no longer costs users a `brew upgrade`. The
  escape hatch when you *do* want it shipped is `workflow_dispatch` with an explicit version.
- `verify.yml` no longer runs on pushes to `main` in its own right; `release.yml` calls it as a
  reusable workflow. One green check per push, not two, and a release can never be cut from a tree
  that has not passed the gate.
- Releases are no longer single-homed. The consequence ADR-0017 accepted at TEAM = 1 and flagged as
  "wrong the day there are two" is resolved before there are two.
- ADR-0017's untested-workflow objection ("the workflow is untestable until a tag fires it") is
  answered only partly: the bump rule has a table test and the build steps are the same `make`
  targets the local lane uses, but the keychain import, the notary API key and the tap push are
  first exercised by the first real CI release. That release is the measurement, and its result goes
  into `docs/runbooks/release.md` next to v0.1.0's — recorded, not glossed.

## Alternatives

- **Hybrid: CI derives the version, tags and drafts the release; the maintainer runs `make release`
  locally to attach the artefact** — rejected. It keeps the key on the laptop, which is genuinely
  better, and it automates the bookkeeping that is genuinely annoying. But every version still
  needs one specific machine, which is the thing being fixed. Kept as the documented recovery path,
  where "a human is already involved" is a premise rather than a cost.
- **Release on a tag push instead of on every push to `main`** — rejected as the primary trigger:
  it moves the version decision back into a human's hands (`git tag v0.1.1`), which is the manual
  step and the drift source. The tag is still created, as an *output* of the lane.
- **Always bump the patch version** — rejected. It ships a version for a typo fix in a runbook, and
  it makes `feat:` and `docs:` indistinguishable in the version history.
- **Default an unparseable subject to a patch bump** — rejected; that is a silent fallback with a
  version number attached, and the resulting release is unattributable to any stated intent.
- **A GitHub App instead of a PAT for the tap push** — deferred, not rejected. It is the better
  credential (short-lived installation tokens, scoped to one repo), and it is worth doing the day
  the PAT needs rotating. A fine-grained PAT with `contents: write` on `homebrew-tap` alone is
  close enough today and needs no app to register.
- **Sign in CI but notarize locally** — rejected as the worst of both: the key is exposed *and* a
  human is still in the loop.
