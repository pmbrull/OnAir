# ADR-0016 — The loopback key never touches a keychain

- Status: **Superseded by [ADR-0019](0019-the-callback-lands-on-a-page-we-host.md)** — there is no
  longer a loopback key to keep out of a keychain, because there is no longer a certificate. The
  invariant it created survives in stronger form: A6 is now "OnAir imports no PKCS#12 archive at
  all", checked so that a future TLS listener cannot quietly bring the problem back.
- Date: 2026-08-14
- Extends: [ADR-0005](0005-oauth-over-a-self-signed-https-loopback.md),
  [ADR-0006](0006-the-token-lives-in-the-keychain.md)

> Kept in full rather than trimmed: the failure below — 268 private keys and a login-password
> prompt a week — is the most expensive thing this repository has learned from a real machine, and
> the reason A6 still exists after its cause was deleted.

## Context

Reported from a real machine: *"I keep having a popup asking for my password due to OnAir requiring
to do stuff with my keychain."*

The cause was not the token. `TokenStore` writes two generic passwords and neither prompts. It was
`LoopbackIdentity`, which turns the PKCS#12 archive minted for the OAuth callback into a
`SecIdentity` the TLS listener can present:

```swift
let options = [kSecImportExportPassphrase as String: archivePassphrase] as CFDictionary
SecPKCS12Import(data as CFData, options, &items)
```

That is the obvious way to write it and it is wrong on macOS. `SecPKCS12Import` there does not hand
back an in-memory identity — it **imports into the default keychain**, permanently, and returns a
reference to what it just stored. Every distinct archive OnAir minted therefore left a certificate
*and its private key* in the user's login keychain, and stayed.

**Measured on the reporting machine**, before any change:

| | Count |
|---|---|
| Certificates `CN=localhost, O=OnAir` in `login.keychain-db` | 268 |
| Private keys labelled `Imported Private Key` | 268 |
| Unrelated private keys on the whole system | 4 |
| PKCS#12 archives on disk | 1 |

All 268 certificates were **distinct**, and that is the diagnostic. `loadOrCreate` reuses the
archive on disk, so the app contributes one; the rest came from `LoopbackTests`, which mints into a
fresh temporary directory per test. `make test` runs it, `make verify` runs `make test`, and the
project gate was the largest single polluter of the user's keychain.

The prompt follows from the keys, not the certificates. A private key imported this way carries an
ACL naming the process that imported it. A rebuilt OnAir — or the `.build` test runner, at a path
that moves — is not that process, so the ACL misses and macOS falls back to the only thing it can
do: ask the human for their login password.

Two facts make the whole thing avoidable. The key is **not a credential**: ADR-0005 already says so
in the source, where the archive passphrase is a hard-coded constant, because the key's only job is
to authenticate `localhost` to this machine's own browser for the seconds a callback is in flight.
And the durable copy that stops the browser warning about a *different* certificate every launch is
the archive on disk — never a keychain entry.

## Decision

**`SecPKCS12Import` passes `kSecImportToMemoryOnly`, and a grep in `make verify` keeps it there.**

- `LoopbackIdentity.importIdentity` adds `kSecImportToMemoryOnly: kCFBooleanTrue`. The identity
  lives in process memory for the lifetime of the connect, and no keychain is touched at all.
- **Invariant A6**, in `scripts/check-architecture.sh`: a `SecPKCS12Import(` call site in `Sources`
  that does not pass `kSecImportToMemoryOnly` fails the build. Matched as the dictionary-key form
  `kSecImportToMemoryOnly *as *String *:`, because the comment above the call names the constant and
  a bare mention would let the check pass on a file where the option had been deleted.
- `LoopbackTests` counts login-keychain private keys and `localhost` certificates either side of
  `loadOrCreate` and fails unless both deltas are zero. It queries attributes only — never
  `kSecReturnRef` or `kSecReturnData` on a key — so the test cannot raise the prompt it prevents.
- `scripts/purge-loopback-keychain.sh` removes what was already stranded. It reports by default and
  deletes only with `--apply`; `make purge-loopback` is the report and `make uninstall` applies it.

**Measured after the change:** two `loadOrCreate` calls move both counts by 0, and all 112 tests
pass — including the loopback cases, which mint a real certificate and complete a real TLS handshake
against `URLSession`. A memory-only `SecIdentity` is good enough for Network.framework. Across nine
subsequent runs — three `make verify`, four `make test`, two forced rebuilds — the key and
certificate counts did not move, and they are stable at rest.

**One run in the middle of that sweep moved the count by 7 and has never reproduced.**
[GAP-0003](../gaps/closed/0003-one-unexplained-keychain-deposit-after-the-fix.md) carries it. A
transitional build state is the story that fits, and it is a story rather than a measurement, which
is why it is a gap and not a paragraph in this Context.

`security delete-identity -Z <hash>` was measured on one stranded item before the bulk run: exit 0,
under a second, **no password prompt**, and the certificate and its private key went together. The
plan had budgeted for up to one prompt per key; that turned out not to be the cost.

## Consequences

- The user stops being asked for their login password, and `make verify` stops charging them a
  keychain entry per run.
- **The deployment target is now load-bearing.** `kSecImportToMemoryOnly` is macOS 15.0+, and
  `Package.swift` declares `platforms: [.macOS(.v15)]`, so no availability guard is needed. Lowering
  the target below 15 breaks this fix silently — the option would simply be unavailable — and would
  need the rejected alternative below in its place.
- The purge script is the one thing in this repo that deletes from a user's login keychain. Its
  licence to exist is that it matches on the certificate's **parsed subject** (`O=OnAir`) rather
  than the `localhost` label; a label match would take somebody's own development certificate with
  it. Dry-run-by-default is the second guard.
- A partial purge exits non-zero and names what it could not remove, because the items left behind
  are exactly the ones still capable of prompting (`.claude/rules/no-silent-fallbacks.md`).

## Alternatives

**Fix the ACL instead — `kSecImportExportAccess` with a permissive `SecAccess`.** Also stops the
prompt, and was rejected because it keeps depositing a key per archive. It trades a visible symptom
for silent unbounded growth in the user's keychain, which is the worse failure precisely because
nothing reports it. The prompt, for all that it is a PITA, was the only thing telling anyone this
was happening.

**Import into a dedicated keychain the app creates, unlocks and deletes.** Keeps the login keychain
clean and works below macOS 15, at the cost of a keychain file to create, a password to invent for
it, and a deletion to get wrong. It stays on the shelf as the fallback if the deployment target ever
drops.

**Delete the stranded items with `security delete-certificate`.** Rejected: it removes the
certificate and leaves the private key, which is the half that raises the prompt. `delete-identity`
removes both, verified by counting keys and certificates either side of a single deletion.

**Match the stranded certificates on their `localhost` keychain label.** Simpler, one `security`
call, no `openssl` — and it would have deleted any `localhost` certificate the user minted for their
own work. Parsing the subject costs a subprocess per certificate and buys the right to run at all.
