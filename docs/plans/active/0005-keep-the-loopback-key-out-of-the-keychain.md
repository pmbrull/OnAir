# Plan 0005 — Keep the loopback key out of the Keychain

- Status: Active
- Date: 2026-08-14
- Input: A user report — macOS repeatedly asks for the login-keychain password on OnAir's behalf —
  traced to `LoopbackIdentity.importIdentity` (ADR-0005 is what put that code there; this plan
  proposes ADR-0016 to bound it).

## Goal

`LoopbackIdentity.loadOrCreate` will stop writing anything to the login keychain. Today every call
to it permanently deposits a certificate **and its private key** there, because `SecPKCS12Import`
on macOS imports into the default keychain unless told otherwise. Each deposited key carries an ACL
naming the process that imported it; when a later, differently-signed binary reaches for one, macOS
falls back to asking the user for the login-keychain password. When this is done the loopback
identity will live in process memory for the seconds it is needed and nowhere else, the machine's
existing litter will be gone, and a grep in `make verify` will stop the regression coming back.

### What was measured, not reasoned

On this machine, before any change:

- **268 certificates** with subject `CN=localhost, O=OnAir` in `login.keychain-db` — all *distinct*,
  so they are not one archive re-imported but one fresh certificate per mint.
- **268 private keys** labelled `Imported Private Key`, against 4 unrelated keys for everything else
  on the system.
- One archive on disk: `~/Library/Application Support/OnAir/loopback.p12`.

The distinctness is the tell. `loadOrCreate` reuses the archive, so the app contributes one
certificate; the other 267 come from `LoopbackTests`, which mints into a fresh temporary directory
per test — eight archives per `make test`, and therefore per `make verify`. The gate has been the
main polluter. (The deposit is per *distinct* archive, not per call: re-importing the same one is
suppressed as a duplicate. Measured — see the decision log.)

A direct probe confirmed the fix before this plan was written: `SecPKCS12Import` with
`kSecImportToMemoryOnly` against that same archive returned `errSecSuccess`, yielded a usable
`SecIdentity` whose subject is `localhost` and whose private key `SecIdentityCopyPrivateKey`
returns, and moved the private-key count by **0**.

## Acceptance criteria

- [x] `make verify` is green.
- [x] `LoopbackTests` gains a case that counts login-keychain private keys and `localhost`
      certificates either side of `LoopbackIdentity.loadOrCreate` and fails unless **both** deltas
      are zero. It queries attributes only — never `kSecReturnRef` or `kSecReturnData` on a key — so
      the test itself cannot raise the prompt it exists to prevent.
- [x] The existing loopback TLS cases still pass unchanged. They mint a real certificate and drive a
      real `NWListener` with `URLSession`; they are what proves a memory-only `SecIdentity` is still
      good enough for Network.framework, and no assertion in them needs to move for that to be true.
- [x] `make verify` run twice in a row leaves the private-key count where it started. Measured, not
      assumed: count, run, count.
- [x] `scripts/check-architecture.sh` fails a `SecPKCS12Import` call site that does not pass
      `kSecImportToMemoryOnly`, and `make verify` runs it.
- [x] `scripts/purge-loopback-keychain.sh` reports every `CN=localhost, O=OnAir` identity in the
      login keychain, deletes none without `--apply`, and deletes nothing else ever. Its match is
      the certificate's parsed subject, not the `localhost` label — a label match would take a
      user's own development certificate with it.
- [ ] After the purge, `security find-certificate -a -c localhost` finds no `O=OnAir` certificate
      and the private-key count is back to 4. *(Awaiting the user's go-ahead: this one deletes from
      their login keychain, so it is theirs to authorise.)*
- [x] `make uninstall` purges them too, so uninstalling stops leaving keys behind. Wired, not
      executed — running it would also remove the app.

## Affected modules

| Path | Change |
|---|---|
| `Sources/SlackKit/OAuth/LoopbackIdentity.swift` | The one-line-plus-comment fix |
| `Tests/SlackKitTests/LoopbackTests.swift` | The leak regression case |
| `scripts/check-architecture.sh` | New invariant A6 |
| `scripts/purge-loopback-keychain.sh` | New — the cleanup |
| `Makefile` | `purge-loopback` target; `uninstall` calls it |
| `ARCHITECTURE.md` | A6 |
| `docs/decisions/0016-*.md` | New ADR |
| `CLAUDE.md`, `docs/dev-loop.md` | The trap, stated where someone will hit it |

**Invariants.** Adds **A6 — the loopback key never touches a keychain**, mechanically checked. It is
the mirror of A4 rather than a contradiction of it: A4 says the *token* goes in the Keychain and
nowhere else; A6 says the loopback key goes in process memory and nowhere else, because it is not a
credential (ADR-0005 already says so — its passphrase is a constant in the source). A4's "only
`TokenStore` may call `SecItem*`" is untouched: the fix removes keychain traffic rather than adding
any, and the new test reads attributes from the test target, which the check already scopes to
`Sources/`.

No behaviour visible in the menu bar changes. The OAuth flow, the browser warning and the
certificate on disk all stay exactly as they are.

## Steps

1. **Write the failing test first.** The private-key/certificate delta case in `LoopbackTests`. Run
   it, watch it fail against today's code by whatever the current per-call delta is, and record that
   number in the decision log — it is the direct measurement of the leak rate.
2. **Fix `importIdentity`.** Add `kSecImportToMemoryOnly` to the options, with a comment saying what
   it prevents and pointing at ADR-0016. Watch the new test go green and the TLS cases stay green.
3. **Add A6 to `check-architecture.sh`** and to `ARCHITECTURE.md`. Verify the check by deleting the
   option locally and confirming `make arch` fails, then putting it back.
4. **Write `scripts/purge-loopback-keychain.sh`.** Dry-run default, `--apply` to delete, subject
   parsed with `/usr/bin/openssl` and matched on `O=OnAir`. Run the dry run; confirm the count it
   reports is 268 and that every hash it lists is one of the ones already inventoried.
5. **Purge, with the user watching.** Deleting a private key is authorised per key, so this may ask
   for the password up to 268 times. Measure it on one item first and pick the route from what that
   shows (step 4's dry run makes that safe to try). If the CLI is unworkable, say so and hand the
   user the Keychain Access route — one multi-select delete, one prompt — rather than pretending the
   script is the only path.
6. **Wire `make purge-loopback` and `make uninstall`**, then re-measure: `make verify` twice, count
   either side.
7. **ADR-0016 and the docs.** The ADR records the decision and the 268; `CLAUDE.md` gets it in the
   trip-you-up list, because "import a PKCS#12 to get a `SecIdentity`" is the obvious thing to write
   and it is wrong on macOS.

## Risks

- **A memory-only `SecIdentity` might not satisfy `sec_identity_create`.** Already probed — the
  identity and its private key both come back — but the probe was not a TLS handshake. The existing
  `LoopbackTests` happy path *is* one, so step 2 either passes it or the fix is wrong; there is no
  quiet middle. Fallback if it fails: import into a dedicated app keychain the app creates, unlocks
  and deletes, which keeps the login keychain clean at the cost of more moving parts.
- **`kSecImportToMemoryOnly` is macOS 15.0+.** `Package.swift` declares `platforms: [.macOS(.v15)]`,
  so no availability guard is needed — but that also means the deployment target is now load-bearing
  for this fix, which the ADR should say out loud.
- **The purge is destructive on the user's login keychain.** Scoping on the parsed `O=OnAir` subject
  rather than the `localhost` label is the mitigation, dry-run-by-default is the second, and the
  hashes are inventoried before deletion so the set can be checked against the count. It does not
  run without `--apply`, and it will not run unasked.
- **The purge may prompt per key.** Measured in step 5 rather than guessed. Worst case the user gets
  one bad minute instead of a prompt a week; that is still the right trade, but they should be told
  which it is before it starts, not during.
- **The 268 keys are the litter, not necessarily every source of the prompt.** If prompts continue
  after the purge, the fix was incomplete and the next suspect is the app bundle's signature
  changing between builds — worth an explicit re-check with the user rather than declaring victory.

## Decision log

`2026-08-14` — Root cause is `SecPKCS12Import`'s macOS default, not anything about ACLs or signing —
because the certificate count is 268 *distinct* certificates against 1 archive on disk, which only
per-mint import explains.

`2026-08-14` — Fix by not importing at all rather than by fixing the ACL. `kSecImportExportAccess`
with a permissive `SecAccess` would also stop the prompt, but it would keep depositing a key per
call and would trade a visible prompt for silent unbounded growth in the user's keychain — the worse
failure, because nothing reports it.

`2026-08-14` — New invariant rather than a comment. This is exactly the line a future change deletes
while "simplifying the import", which is the same shape as the `http://` trap ADR-0005 guards, so it
gets a grep and not a paragraph.

`2026-08-14` — The leak is per *distinct archive*, not per call. Measured: two `loadOrCreate` calls
on one archive moved the key count by 1, not 2 — the keychain suppresses the re-import as a
duplicate. That is why 268 stranded certificates were 268 *distinct* certificates, and why the test
suite (a fresh archive per test) outpaced the app (one archive, reused) as a polluter. The plan's
"four `SecPKCS12Import` calls per `make test`" was the wrong model; the comments were corrected to
match the measurement rather than the other way round.

`2026-08-14` — The A6 check matches `kSecImportToMemoryOnly *as *String *:`, not the bare constant.
Caught by testing the check itself: deleting the option left the doc comment above it, which names
the constant, and a bare `grep` passed on a file where the fix had been removed. A guard that can be
satisfied by the comment explaining it is not a guard. The call-site match also gained an open paren
so the prose mention stops being reported as a second violation.

`2026-08-14` — `mapfile` → `while read` in the purge script. `/bin/bash` on macOS is 3.2, which has
no `mapfile`; it only ran here because Homebrew's bash 5.3 is first on `PATH`. A cleanup script that
runs only on a developer's machine is not a cleanup script.

`2026-08-14` — Deletion costs nothing. Measured on one stranded identity before the bulk run:
`security delete-identity -Z` exited 0 in under a second with **no password prompt**, and the
certificate and its private key went together (300 → 299 certificates, 300 → 299 keys). Step 5's
budget of up to one prompt per key was wrong, and the Keychain Access fallback is not needed.

`2026-08-14` — One verify run added 7 keys *after* the fix and never did so again — nine clean runs
either side, stable at rest, forced rebuilds clean. Recorded as
[GAP-0003](../../gaps/open/0003-one-unexplained-keychain-deposit-after-the-fix.md) rather than
explained away: a transitional build state fits the number, and "fits" is not "measured".
