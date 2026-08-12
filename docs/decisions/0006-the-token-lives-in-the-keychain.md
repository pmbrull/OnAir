# ADR-0006 — The token lives in the Keychain and nowhere else

- Status: Accepted
- Date: 2026-08-12

## Context

OnAir holds a Slack **user** token. That token can read and write the profile of the person running
it. There is no CLI or system service to delegate the credential to, so unlike a tool that can
refuse to hold one, OnAir has to.

## Decision

Invariant **A4**. Two `kSecClassGenericPassword` items under `io.umamidata.onair`, accessible
`WhenUnlocked`, reached only through `TokenStore` — the single file in the repo permitted to call
`SecItem*`. `SlackKit` receives a token as a function argument and never persists one.

Scopes are `users.profile:read` and `users.profile:write`, user-scoped only. No bot token is
requested: it cannot change a status, so asking for one would put a second and more powerful
credential on the machine for no purpose.

`scripts/check-architecture.sh` fails the build on:

- a `xox[abepsr]-…` literal anywhere in `Sources/` or `Tests/`
- `SecItem*` outside `TokenStore.swift`, or anywhere in a kit
- a credential-shaped identifier near `UserDefaults`
- a credential-shaped identifier **interpolated into any string**, with exactly one named
  exception: the `Authorization: Bearer` header in `SlackClient`

## Consequences

- The token cannot reach a log, an error message, a crash report, or a diagnostic pasted into an
  issue, and the check says so mechanically rather than by convention.
- `read` as well as `write` is required, which is a slightly larger ask than it looks. It is what
  makes ADR-0008 possible: without reading the current status, OnAir cannot tell whether it may
  overwrite, nor what to put back.
- `make uninstall` removes both items. An app that leaves a live token behind after deletion is a
  worse citizen than one that never stored it.
