# Runbook — cutting a release

How OnAir gets from a green `main` to `brew install --cask pmbrull/tap/onair`.

**Since ADR-0018, cutting a release is merging a PR.** `.github/workflows/release.yml` does the rest:
verify, derive the version, build, sign, notarize, tag, publish, push the cask. §6 is the whole
of "every release", and it is one sentence long.

The rest of this page is the one-time setup that makes that true (§1–§5), and the manual lane that
`make release` still is when CI cannot do it (§7). The mechanics live in the Makefile and
`scripts/`; ADR-0017 chose the channel and the artefact, ADR-0018 moved the lane into CI.

Everything in the local lane runs with the Command Line Tools alone: `notarytool` and `stapler` ship
in CLT (`/Library/Developer/CommandLineTools/usr/bin/`), and `codesign`, `ditto`, `lipo`, `iconutil`
and `spctl` are system binaries. No Xcode required.

## 0. One-time — a fresh machine

Only needed to run the lane *locally* (§7) or to develop. A release does not need this machine.

```bash
xcode-select --install                      # Command Line Tools — the only toolchain needed
xcrun --find notarytool && xcrun --find stapler   # both must resolve (see below)
brew install gh                             # publishing talks to GitHub releases
gh auth login
git clone git@github.com:pmbrull/OnAir.git && cd OnAir
make verify                                 # green before anything else
```

- The two `xcrun --find` lines are the load-bearing check: both tools resolved inside CLT on the
  machine this runbook was measured on. If either is missing, update the CLT (or install Xcode —
  overkill, but sufficient).
- `swiftformat`/`swiftlint` absent is fine — `make verify` says SKIP for those locally and CI
  enforces them; `brew install swiftformat` if you want the check local.

## 1. One-time — the Developer ID certificate

Needs an active [Apple Developer Program](https://developer.apple.com/programs/) membership, and
the **Account Holder** role (only that role can create Developer ID certificates).

1. **Create a signing request** (this generates the private key, directly in your keychain):
   Keychain Access → menu **Keychain Access → Certificate Assistant → Request a Certificate From
   a Certificate Authority…** → your Apple ID email, common name as you like, **Saved to disk**.
2. **Mint the certificate**: [developer.apple.com/account](https://developer.apple.com/account) →
   **Certificates** → **+** → **Developer ID Application** → upload the `.certSigningRequest` →
   download the `.cer`.
3. **Install it**: double-click the `.cer` (it pairs with the private key from step 1 in the
   login keychain).
4. **Verify**:

   ```bash
   security find-identity -v -p codesigning
   # → 1) <fingerprint> "Developer ID Application: Your Name (TEAMID)"
   ```

   If it says `0 valid identities`, the usual cause is a missing Apple intermediate — download
   the **Developer ID – G2** intermediate from
   [apple.com/certificateauthority](https://www.apple.com/certificateauthority/) and install it.

5. **Export it for CI**, since ADR-0018 signs on a runner. Keychain Access → **My Certificates** →
   the `Developer ID Application:` row → **Export…** → `.p12`.

   ```bash
   openssl rand -base64 24 | tr -d '\n' | pbcopy       # the passphrase; paste it into the dialog
   base64 -i DeveloperID.p12 | tr -d '\n' | pbcopy     # → DEVELOPER_ID_P12_BASE64
   ```

   **The passphrase is not optional.** Keychain Access will happily export with an empty one, and the
   release job then fails at `Missing secrets`: an empty `DEVELOPER_ID_P12_PASSWORD` is
   indistinguishable from a secret nobody set, and guessing which it was is exactly the silent
   fallback this repo refuses. Meanwhile an unprotected `.p12` is your signing key readable by
   anything running as you. Measured 2026-08-15, on the first export.

   Verify the archive before uploading it — the mistake that costs the most time is exporting the
   certificate without its private key, which fails much later inside `codesign`:

   ```bash
   /usr/bin/openssl pkcs12 -in DeveloperID.p12 -nokeys -clcerts | /usr/bin/openssl x509 -noout -subject
   /usr/bin/openssl pkcs12 -in DeveloperID.p12 -nocerts -nodes | grep -c 'PRIVATE KEY'   # must be > 0
   ```

   `/usr/bin/openssl`, deliberately: Keychain encrypts the certificate bag with **RC2-40-CBC**, which
   OpenSSL 3 (a `brew install openssl` on `PATH`) refuses as legacy —
   `unsupported ... Algorithm (RC2-40-CBC : 0)`. macOS ships LibreSSL, which reads it; `-legacy` also
   works on OpenSSL 3. None of this reaches CI, which imports with `security import` — Apple's own
   code, reading Apple's own format.

   Then delete the `.p12` from disk. It becomes two repository secrets (§5) and a backup somewhere
   encrypted; it is never a file in this repo and never a file left in `~/Downloads`.

The private key itself stays in your login keychain. If it ever leaks, revoke the certificate at
[developer.apple.com/account](https://developer.apple.com/account) → **Certificates** → the
Developer ID → **Revoke**, and mint a new one: compromise costs a re-release, not the ability to
ship.

## 2. One-time — notary credentials

Two forms, because the two lanes authenticate differently — deliberately (ADR-0018). The Makefile's
`NOTARY_AUTH` variable is the seam; both drive the same `make notarize`.

**Local (`make release`): an app-specific password in the keychain.**

1. [account.apple.com](https://account.apple.com) → **Sign-In and Security → App-Specific
   Passwords** → generate one (call it `onair-notary`).
2. Team ID: [developer.apple.com/account](https://developer.apple.com/account) → **Membership
   details**.
3. Store the profile — **give no `--password` flag**; the tool prompts with hidden input, which
   keeps the credential out of shell history and `ps`:

   ```bash
   xcrun notarytool store-credentials onair-notary \
     --apple-id <your-apple-id-email> --team-id <TEAMID>
   ```

**CI: an App Store Connect API key.** An app-specific password unlocks the whole Apple ID; an API
key is scoped to the API and revocable by itself, which is what belongs in a repository secret.

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Users and Access** →
   **Integrations** → **App Store Connect API** → **Team Keys** → **+**. Access: **Developer**.
2. Download the `.p8` — **once**; Apple will not show it again.
3. Copy three values: the **Key ID** (next to the key), the **Issuer ID** (above the table), and the
   `.p8` contents. They become three repository secrets (§5).

## 3. One-time — the tap

1. Create a public GitHub repo named exactly **`homebrew-tap`** under `pmbrull`, containing a
   `Casks/` directory.
2. Mint a token for CI to push to it: [github.com/settings/tokens](https://github.com/settings/tokens)
   → **Fine-grained tokens** → **Generate new token** → repository access **Only select
   repositories → pmbrull/homebrew-tap**, permission **Contents: Read and write**, and nothing else.
   That becomes `HOMEBREW_TAP_TOKEN` (§5). Scoped to one repo so the worst it can do is publish a bad
   cask, which is `brew`-visible and revertible.
3. Homebrew expands `pmbrull/tap` to `github.com/pmbrull/homebrew-tap`, so once `Casks/onair.rb`
   exists there, the user-facing install is:

   ```bash
   brew install --cask pmbrull/tap/onair
   ```

Graduating to the official `homebrew/cask` repo later needs no rework — the same file moves over
— but its audit gates on project notability (on the order of 75 GitHub stars / 30 forks / 30
watchers at the time of writing), which a new repo does not have. The tap is the channel until
then.

## 4. One-time — things that are not build steps

- **A LICENSE file.** Done — MIT, at the repo root. Chosen for the half that matters to a tool
  people install from a tap: the AS-IS warranty disclaimer and the liability cap. It also grants
  source rights, which was the accepted trade rather than an oversight.
- **Slack-side distribution.** Confirm the shared app has **Activate Public Distribution** done
  ([shared-app runbook §3](shared-app.md)) — without it, every workspace except the app's home
  fails to connect with `invalid_team_for_non_distributed_app`. The app registration itself never
  changes per release.
- **First-run UX.** A brew-installed user's first Connect still hits the self-signed-certificate
  warning; [first-run.md](first-run.md) is the page to link from release notes.
- **Squash-only merges, titled from the PR.** The bump rule reads the subject of the commit that
  lands on `main`, so which commit that is has to be predictable:

  ```bash
  gh api -X PATCH repos/pmbrull/OnAir \
    -F allow_squash_merge=true -F squash_merge_commit_title=PR_TITLE \
    -F squash_merge_commit_message=COMMIT_MESSAGES \
    -F allow_merge_commit=false -F allow_rebase_merge=false
  ```

  Three separate traps, all closed by that one call. GitHub's default
  `squash_merge_commit_title=COMMIT_OR_PR_TITLE` uses the **commit** subject when a PR holds exactly
  one commit and the **PR title** when it holds several — so the same PR title would decide the
  version or not depending on how many times you committed. A **merge commit** yields
  `Merge pull request #12 from …`, which carries no type at all and fails the job. A **rebase merge**
  puts every branch commit on `main` and the rule reads only the last one, silently ignoring the
  `feat:` three commits back. Squash, titled from the PR, is the only shape where the version follows
  from something you deliberately wrote.
- **Branch protection on `main`.** Since ADR-0018, a push to `main` signs and notarizes code as you.
  That makes review-before-merge a code-signing control, not only a code-review one. Named here
  because the ADR names it as follow-up and does not do it.

## 5. One-time — the six repository secrets

`gh secret set <NAME> --repo pmbrull/OnAir`, or Settings → Secrets and variables → Actions. Six, and
the workflow fails with a named error if any is missing rather than signing something wrong.

| Secret | From | Notes |
|---|---|---|
| `DEVELOPER_ID_P12_BASE64` | §1.5 | base64 of the `.p12`, newlines stripped |
| `DEVELOPER_ID_P12_PASSWORD` | §1.5 | the export passphrase |
| `NOTARY_API_KEY_P8` | §2 | the whole `.p8`, `-----BEGIN…` line included |
| `NOTARY_API_KEY_ID` | §2 | ~10 characters |
| `NOTARY_API_ISSUER_ID` | §2 | a UUID |
| `HOMEBREW_TAP_TOKEN` | §3.2 | fine-grained, `homebrew-tap` only, Contents: write |

`gh secret set NOTARY_API_KEY_P8 --repo pmbrull/OnAir < AuthKey_XXXXXXXX.p8` reads from the file
rather than your shell history. Delete the `.p8` afterwards.

## 6. Every release

Merge a PR into `main`. That is the whole procedure.

`.github/workflows/release.yml` then, in order:

1. Runs the gate — `verify.yml`, called rather than copied, so a release cannot come from a red tree.
2. Derives the version from the squashed commit subject (`scripts/next-version.sh`):
   `feat:` → minor, `fix:`/`perf:`/`revert:` → patch, breaking → minor while the major is `0`.
   `docs:`/`chore:`/`ci:`/`test:`/`refactor:`/`style:`/`build:` release nothing and the run says so.
   **A subject that is not a Conventional Commit fails the job** — it does not default to a patch.
3. Bumps `Resources/Info.plist` **in the working tree only**, builds the universal binary, signs it
   with a Developer ID identity in an ephemeral keychain, notarizes, staples, assesses.
4. Only now touches anything outside the runner: commits `chore(release): vX.Y.Z [skip ci]`, tags,
   pushes, `gh release create`, then regenerates the cask from the **published** asset and pushes it
   to the tap.

So a failure in 1–3 leaves no bumped version, no tag, no release and no cask change. A failure in 4
is the one that needs a human — see §7.

**To force a version** (a `1.0.0`, or a `docs:` change you do want shipped): Actions → **release** →
**Run workflow** → fill in `version`. CI never promotes the project past `0.x` on its own; declaring
stability is a claim a person makes.

**To check on it:** the run's summary prints the version, the sha256, the archs, and the
`brew upgrade` line. Then prove it as a stranger would:

```bash
brew update && brew upgrade --cask pmbrull/tap/onair
open -a OnAir
```

## 7. The manual lane — recovery, and releases without CI

`make release` is unchanged and is what you run when Actions is down, when a run died after step 4
had started, or when you need to release from a machine. It is also the only way to *finish* a
half-done release, because `release.yml` refuses a version that is already tagged.

1. **Version.** In `Resources/Info.plist`: bump `CFBundleShortVersionString` (semver, becomes the
   tag and the zip name) and `CFBundleVersion` (integer, +1 every release), or let
   `./scripts/bump-version.sh X.Y.Z` do both. The Makefile reads the version from the plist;
   nothing else declares it.
2. **The bar.** `make verify`, then `make doctor` against real hardware, then the app itself
   (`make run`) — the same gate as any change (docs/agent-workflow.md).
3. **Build and notarize:**

   ```bash
   make release
   ```

   That is `dist` (two `--triple` builds → `lipo` → hardened-runtime Developer ID signature →
   `ditto` zip → sha256) then `notarize` (`notarytool submit --wait` → `stapler staple` → re-zip
   → `spctl --assess`). It ends by printing step 4 with the version filled in. Expect
   `--wait` to take a few minutes; `spctl` must say **Notarized Developer ID**.
4. **Tag and publish** (printed by `make release`):

   ```bash
   git tag v<version> && git push origin v<version>
   gh release create v<version> '.build/dist/OnAir-<version>.zip' --title 'OnAir <version>'
   ```

   The zip name and the tag must match what the cask's `url` computes — both derive from the
   plist version, so they do.
5. **Update the tap:** `./scripts/make-cask.sh` downloads the zip you just published from the
   GitHub release, hashes **that**, and renders the cask — so the sha256 can never drift from
   the asset users fetch, even if `make dist` was rerun in between.
   `HOMEBREW_TAP_TOKEN=… ./scripts/publish-cask.sh` pushes it, or paste the output into
   `homebrew-tap/Casks/onair.rb` by hand. (`make-cask.sh --local` hashes `.build/dist` instead —
   lane testing only, never for shipping.)
6. **Commit the plist bump** to `main`, so the next automated release does not derive a version that
   has already shipped.
7. **Prove it as a stranger would** — `brew update && brew install --cask pmbrull/tap/onair`, the
   menu-bar icon appears, `doctor` behaves, Connect works. Only now is the release done.

## What the first real release measured

v0.1.0 shipped 2026-08-14 through the manual lane, and that lane ran for the first time. What had
been recorded here as unmeasured is now measured:

- **notarytool Accepted the bundle**, submission `0dc7fb88-b0bc-4c53-a9a0-328f146e7048`, first
  try, no changes to the signing flags. `stapler` stapled it and `spctl --assess` answered
  `accepted / source=Notarized Developer ID` — both on the build directory and, afterwards, on the
  brew-installed `/Applications/OnAir.app`.
- **`brew install --cask pmbrull/tap/onair` works** end to end from a clean tap.
- The **`depends_on macos:` string form is deprecated**, which only the real install revealed:
  Homebrew warned at `Casks/onair.rb:10` and named `macos: :sequoia` as the replacement. The bare
  symbol is the same constraint — `MacOSRequirement` defaults its comparator to `>=` —
  so `scripts/make-cask.sh` now emits it. Still a warning today; on its way to an error.

Still unmeasured, and left recorded rather than assumed:

- **The CI lane, end to end.** ADR-0018 is built and its bump rule has a table test, but the
  keychain import, the App Store Connect notary key and the tap push are first exercised by the
  first release that runs through Actions. That release is the measurement; its result belongs in
  this section, next to v0.1.0's.
- The **Keychain consent prompt on upgrade from a dev build**: the Slack token was written by a
  differently-signed binary, so the first Developer-ID-signed launch asks once before reading
  it. Expected behaviour, not a bug; a fresh install never sees it. The machine that cut v0.1.0
  had no stored token at the time, so this path did not run.
- Whether a **CI-signed** binary and a **locally-signed** one are interchangeable to the Keychain.
  They carry the same certificate, so they should be — but "should be" is what this section exists
  to stop us writing.

## When something refuses

| Symptom | Meaning |
|---|---|
| The release job says `Undecidable version` | The squashed commit subject is not a Conventional Commit. Nothing was published. Amend the subject on a follow-up, or dispatch the workflow with an explicit version |
| …and the subject is `Merge pull request #N from …` | The PR was merged with a merge commit rather than squashed. GitHub writes that subject, and no rule can read a version out of it — squash-merge, or dispatch with an explicit version |
| …and the subject is a commit subject you wrote, not the PR title | `squash_merge_commit_title` is still `COMMIT_OR_PR_TITLE`, which prefers the commit subject on a one-commit PR — §4 has the `gh api` call that pins it to `PR_TITLE` |
| The release job says `Already tagged` | A previous run died after tagging. Finish it with §7 from step 3 — do not re-run the workflow |
| The release job says `Wrong identity` | The `.p12` in secrets is not a Developer ID Application certificate (an Apple Development one signs fine locally and is refused by every other Mac) |
| The release job says `Missing secrets` and you did set them | `DEVELOPER_ID_P12_PASSWORD` is empty because the `.p12` was exported without a passphrase — re-export per §1.5 |
| `openssl` locally → `unsupported ... RC2-40-CBC` | OpenSSL 3 refusing Keychain's legacy cipher. Use `/usr/bin/openssl` or add `-legacy`; the export is fine and CI never sees this |
| `codesign` → `errSecInternalComponent` | Keychain locked (common over SSH): `security unlock-keychain login.keychain-db` |
| `notarytool` verdict `Invalid` | `xcrun notarytool log <submission-id> --keychain-profile onair-notary` — per-file reasons, usually a missing hardened runtime or timestamp |
| `notarytool` → `HTTP 401` in CI | The App Store Connect key was revoked, or the `.p8` secret lost a line. Regenerate per §2 |
| `spctl` → `rejected` before `notarize` ran | Normal — assessment passes only after stapling |
| `brew` says checksum mismatch | The tap's `sha256` is from a different zip than the release asset — rerun `scripts/make-cask.sh` (it hashes the published asset) and re-push the cask |
| The release published but the tap did not | `HOMEBREW_TAP_TOKEN` expired. Re-mint per §3.2, then §7 step 5 |
| A workspace's Connect fails with `invalid_team_for_non_distributed_app` | Slack-side distribution never activated — [shared-app.md §3](shared-app.md) |
