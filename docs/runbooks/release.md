# Runbook — cutting a release

How OnAir gets from a green `main` to `brew install --cask pmbrull/tap/onair`. The mechanics live
in `make release` (ADR-0016); this is the walkthrough, split into **one-time setup** (§1–§4) and
**every release** (§5). Written when this machine had zero codesigning identities — §1 starts
from nothing.

Everything here runs with the Command Line Tools alone: `notarytool` and `stapler` ship in CLT
(`/Library/Developer/CommandLineTools/usr/bin/`), and `codesign`, `ditto`, `lipo`, `iconutil` and
`spctl` are system binaries. No Xcode required.

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

Keep the private key backed up (Keychain Access → export as `.p12`, to somewhere encrypted). The
key never enters this repo, GitHub secrets, or any file here — ADR-0016.

## 2. One-time — notary credentials

Notarization authenticates with an app-specific password, stored once in the keychain under the
profile name `make notarize` uses (`onair-notary`):

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

The password lands in the keychain, nowhere else — the same rule the Slack token lives by.

## 3. One-time — the tap

1. Create a public GitHub repo named exactly **`homebrew-tap`** under `pmbrull`, containing a
   `Casks/` directory.
2. That is all. Homebrew expands `pmbrull/tap` to `github.com/pmbrull/homebrew-tap`, so once
   `Casks/onair.rb` exists there, the user-facing install is:

   ```bash
   brew install --cask pmbrull/tap/onair
   ```

Graduating to the official `homebrew/cask` repo later needs no rework — the same file moves over
— but its audit gates on project notability (on the order of 75 GitHub stars / 30 forks / 30
watchers at the time of writing), which a new repo does not have. The tap is the channel until
then.

## 4. One-time — things that are not build steps

- **A LICENSE file.** The repo ships none, which legally means all-rights-reserved — fine for a
  private repo, wrong for one people install from. Picking it is an ownership call, not an agent
  call; MIT is the default suggestion for a tool like this.
- **Slack-side distribution.** Confirm the shared app has **Activate Public Distribution** done
  ([shared-app runbook §3](shared-app.md)) — without it, every workspace except the app's home
  fails to connect with `invalid_team_for_non_distributed_app`. The app registration itself never
  changes per release.
- **First-run UX.** A brew-installed user's first Connect still hits the self-signed-certificate
  warning; [first-run.md](first-run.md) is the page to link from release notes.

## 5. Every release

1. **Version.** In `Resources/Info.plist`: bump `CFBundleShortVersionString` (semver, becomes the
   tag and the zip name) and `CFBundleVersion` (integer, +1 every release). The Makefile reads
   the version from the plist; nothing else declares it.
2. **The bar.** `make verify`, then `make doctor` against real hardware, then the app itself
   (`make run`) — the same gate as any change (docs/agent-workflow.md). CI must be green on the
   release commit.
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
   the asset users fetch, even if `make dist` was rerun in between. Commit the output to
   `homebrew-tap/Casks/onair.rb`, push. (`--local` hashes `.build/dist` instead — lane testing
   only, never for shipping.)
6. **Prove it as a stranger would:**

   ```bash
   brew update && brew install --cask pmbrull/tap/onair
   open -a OnAir
   ```

   The menu-bar icon appears, `doctor` behaves, Connect works. Only now is the release done.

## What the first real release measures

The lane below `notarize` is exercised (`make dist DIST_SIGN_ID=-` runs everything but Apple);
Apple's half is not, until a real submission happens. Unmeasured until then, in GAP spirit —
recorded, not assumed:

- Whether notarytool **Accepts** the bundle as signed here (hardened runtime on, timestamp on,
  no entitlements, no camera keys — all the known requirements are met).
- The **Keychain consent prompt on upgrade from a dev build**: the Slack token was written by a
  differently-signed binary, so the first Developer-ID-signed launch asks once before reading
  it. Expected behaviour, not a bug; a fresh install never sees it.

## When something refuses

| Symptom | Meaning |
|---|---|
| `codesign` → `errSecInternalComponent` | Keychain locked (common over SSH): `security unlock-keychain login.keychain-db` |
| `notarytool` verdict `Invalid` | `xcrun notarytool log <submission-id> --keychain-profile onair-notary` — per-file reasons, usually a missing hardened runtime or timestamp |
| `spctl` → `rejected` before `notarize` ran | Normal — assessment passes only after stapling |
| `brew` says checksum mismatch | The tap's `sha256` is from a different zip than the release asset — rerun `scripts/make-cask.sh` (it hashes the published asset) and re-push the cask |
| A workspace's Connect fails with `invalid_team_for_non_distributed_app` | Slack-side distribution never activated — [shared-app.md §3](shared-app.md) |
