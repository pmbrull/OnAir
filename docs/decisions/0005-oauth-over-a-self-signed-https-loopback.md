# ADR-0005 — OAuth over a self-signed HTTPS loopback

- Status: Accepted
- Date: 2026-08-12

## Context

Slack's documentation is explicit: *"The `redirect_uri` must use HTTPS… A Redirect URL must also
use HTTPS."* Its list of invalid examples is all `http://`. There is **no localhost exception** —
the loopback flow that RFC 8252 recommends for native apps, and that most OAuth providers allow
over plain HTTP, is not available here.

That leaves three shapes for a desktop app:

1. `https://localhost:PORT/callback` with a certificate the app mints itself.
2. A hosted HTTPS page that redirects on to `http://127.0.0.1:PORT`.
3. No callback at all: show the code and have the user paste it.

## Decision

**(1).** `LoopbackIdentity` mints a self-signed `localhost` certificate on first use;
`LoopbackReceiver` binds `https://localhost:51234/callback` with `requiredInterfaceType = .loopback`
and accepts exactly one authorisation.

The client id and secret are **not** compiled in. The user creates the Slack app anyway to get a
client id, so both go into Settings once and into the Keychain. A secret shipped inside a
distributed binary is extractable by anyone who downloads it, and calling it a secret would be
telling users something false about what protects their account.

Minting shells out to `/usr/bin/openssl` with an argument array and a written config file — Apple
ships no public API that produces an X.509 certificate, and hand-rolling an ASN.1 writer is a lot
of security-critical code to own for one certificate (ADR-0004). Verified against the LibreSSL
3.3.6 that macOS ships: the SAN lands correctly and `SecPKCS12Import` reads the archive back.

The archive's passphrase is a constant in the source, and deliberately not a secret: it protects a
key whose only job is to authenticate `localhost` to this machine's own browser for the few seconds
a callback is in flight. Putting it in the Keychain would imply the key is worth something
off-machine, and it is not.

## Consequences

- **The authorisation code never leaves the machine.** No third party is in the path.
- The browser shows "your connection is not private" once per browser. The user has to click
  through it. This is the price, it is documented in Settings and in the README, and it is a
  one-time click rather than a recurring one because the archive is reused across launches.
- Port 51234 is fixed, because it has to match the Redirect URL registered in the Slack app. If
  something else holds it, Connect fails with `portUnavailable` and says so.
- `state` is 256 bits from `SecRandomCopyBytes`, and a mismatch discards the code unexchanged.

## Alternative rejected

**(2)**, the hosted bounce page, gives a clean browser experience and near-zero code. It also puts
a live authorisation code in a third party's access logs. The code is single-use, expires in ten
minutes, and is useless without the client secret — but for an app whose whole premise is "this
watches your camera and nothing leaves your machine", one browser warning is the cheaper price.
**(3)** is safe and unpleasant, and was explicitly not what was asked for.
