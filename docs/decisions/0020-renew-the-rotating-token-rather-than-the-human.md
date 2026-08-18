# ADR-0020 — Renew the rotating token, rather than the human

- Status: **Accepted**
- Date: 2026-08-18
- Extends: [ADR-0006](0006-the-token-lives-in-the-keychain.md),
  [ADR-0012](0012-a-public-client-pkce-and-no-secret-anywhere.md)
- Answers half of [GAP-0002](../gaps/open/0002-pkce-flow-unverified-against-a-live-workspace.md)

## Context

Reported from the machine that runs OnAir every day: *"slack token expires every day? I don't want
to have to login daily."*

`make doctor-slack` on 2026-08-18, against a credential minted on 2026-08-13:

```
Slack
  client id             built-in shared app
  user credential       present in the Keychain
  Slack refused the call: token_expired
```

That is the answer to GAP-0002's second question, and it is the opposite of what the plan behind
ADR-0012 assumed. The credential OnAir stores **expires**. `token_expired` is what a *rotating*
token answers once its `expires_in` — 43,200 seconds, twelve hours — has passed, so a laptop shut
overnight comes back to a dead connection, and OnAir, which read nothing but `authed_user.access_token`
out of the exchange, had no way to do anything about it but show **Reconnect Slack**.

Three things about Slack's side, which is where the constraint comes from:

- Rotation is documented as forced only for a **custom URI scheme** redirect ("Slack will always
  issue a rotating token even if the 'token rotation' setting is turned off"). OnAir redirects to an
  `https` page (ADR-0019), so this is not why.
- Which leaves `token_rotation_enabled` being on in the shared app's settings, despite the manifest
  in the README asking for `false`. **Unverified**: nothing in this repository can read that toggle,
  and the observation above is equally consistent with an expiry imposed some other way.
- Rotation **cannot be turned off once on**: "Token rotation may not be turned off once it's turned
  on." So the toggle is not a lever this app can pull, whatever it currently reads.

The cheap fix — register a new Slack app with rotation off and ship its client id — makes every
installed copy reconnect once, requires the maintainer to hold a setting right forever, and leaves
OnAir exactly as defenceless the next time an expiry appears from a direction nobody predicted.

## Decision

**OnAir holds the whole credential and renews it itself.**

- `SlackWire.credential` replaces `userAccessToken` and reads all three fields Slack sends:
  `access_token`, `expires_in`, `refresh_token`. Absent `expires_in` means non-expiring, which is
  the pre-rotation shape and stays supported; an `expires_in` that is present but unreadable
  **throws**, because reading it as "never expires" would disable the renewal loop silently.
- `SlackOAuth.renew` posts `client_id`, `grant_type=refresh_token` and `refresh_token` to the same
  `oauth.v2.access`. Still no secret, still a public client (ADR-0012). No `code_verifier`: the
  verifier proved the authorisation, and there is no browser here to intercept anything.
- **The decision of *when* is a pure function** — `TokenRefresh.plan(for:now:)` — in `SlackKit`,
  with tests. It renews five minutes early, treats an already-expired credential as due rather than
  hopeless, and reports "expires and cannot be renewed" as its own case.
- The refresh token goes in a **second Keychain item** (`slack-renewal`), written **before** the
  access token. `TokenStore` remains the only door (A4). The order is load-bearing: Slack's refresh
  tokens are single-use, so a crash between the two writes must not be the one that loses the
  renewable half.
- `AppCoordinator` renews at launch, when the plan says a renewal is due before any call, once more
  if Slack answers `token_expired` anyway, and on a timer at `expiry - skew`. Renewals are
  single-flight, because two of them race for a single-use token and the loser breaks the chain.
- **A renewal Slack refuses is a disconnection; one that never reached Slack is not.** An
  `ok: false` means the chain is spent, revoked or past its thirty days, and only a human can fix
  it — so the menu turns red. A transport failure leaves the current credential valid until its own
  expiry, so OnAir backs off and tries again rather than declaring a disconnection over dropped
  Wi-Fi.
- Invariant A4's two greps learn the new credential's name: a `refreshToken` in `UserDefaults` or
  interpolated into any string fails the build, exactly as the access token does.

## Consequences

- A connection made once survives, as long as OnAir runs at least once every **thirty days** —
  Slack caps refresh tokens at thirty days for PKCE apps, and each renewal issues the next one. That
  is the honest ceiling, and the README says thirty days rather than "forever".
- OnAir now makes a Slack call the user did not ask for, roughly twice a day. It writes a history
  line when it does, because a background call that touches a credential should be visible
  (`.claude/rules/no-silent-fallbacks.md`).
- A credential that expires with no refresh token — a shape Slack is not known to send — is reported
  the moment it is seen instead of at the deadline.
- One more Keychain item to remove: `make uninstall` deletes it, and the runbook says so.
- **The proof is a next-day observation.** Every test here can pass while the real renewal fails:
  the renewal response's shape for a *user* token is documented only for bots, and both plausible
  shapes are accepted precisely because nothing has measured which one arrives. GAP-0002 stays open
  until a credential has outlived its own expiry with no human involved.

## Alternatives

- **A new Slack app with rotation off.** Cheapest to build, and it is still worth doing if the
  toggle turns out to be the cause — but on its own it costs every user a reconnect, cannot be
  verified from here, and leaves the app unable to survive the next expiry. It is a *complement* to
  this decision, not a substitute.
- **Renew on failure only, with no schedule.** Simpler, and it makes the first call after every
  expiry fail once. That call is the one that sets a status when a meeting starts, so the cost lands
  exactly where it is least acceptable.
- **Store the refresh token beside the access token in the existing item.** One round trip fewer, at
  the price of changing the shape of the item every installed copy reads at launch — an upgrade that
  logs everyone out to save a Keychain read.
- **Ask the user to reconnect, but nag earlier.** The status quo with better manners. It still
  spends a human's attention twice a day on something a machine can do.
