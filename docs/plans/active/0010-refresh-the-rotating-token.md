# Plan 0010 — Refresh the rotating token instead of asking the human every morning

- Status: Active
- Date: 2026-08-18
- Input: GAP-0002 (token longevity unverified), ADR-0012 (public client, PKCE, no secret),
  ADR-0006 (the token lives in the Keychain)

## Goal

The shared Slack app issues **rotating** tokens, so the stored credential dies 12 hours after it is
minted and OnAir — which has no refresh loop at all — sends the user back to **Connect to Slack**
every morning. When this is done OnAir holds the refresh token alongside the access token, renews
the access token before it expires and after a `token_expired`, and a connection made once keeps
working for as long as the app is used at least once every 30 days.

### What measurement says, and what it does not

`make doctor-slack` on 2026-08-18 against Collate, with a credential minted 2026-08-13:

```
Slack
  client id             built-in shared app
  user credential       present in the Keychain
  Slack refused the call: token_expired
```

That answers the second half of GAP-0002: **the token in this configuration expires.** It does not
say *why*. Slack documents rotation as forced only for custom URI schemes ("Slack will always issue
a rotating token even if the 'token rotation' setting is turned off"), and OnAir redirects to an
`https` page — so the likeliest cause is that `token_rotation_enabled` is on in the shared app's
settings despite the manifest in the README setting it `false`. Rotation cannot be switched back
off once on ("Token rotation may not be turned off once it's turned on"), which is why this plan
teaches OnAir to refresh rather than chasing a setting.

The refresh path is what makes OnAir correct under *either* answer: if rotation is on, it renews; if
it is off and the expiry came from somewhere else entirely (an org session policy, say), Slack sends
no `refresh_token`, and OnAir says exactly that instead of pretending the connection is durable.

## Acceptance criteria

- [ ] `make verify` is green.
- [ ] `oauth.v2.access` responses carrying `expires_in` and `refresh_token` parse into a credential
      that holds all three fields; responses carrying neither parse into a non-expiring credential.
      Both shapes covered in `SlackWireTests`.
- [ ] A response with `expires_in` and **no** `refresh_token` does not read as refreshable — it
      produces a credential OnAir reports as "expires, and cannot be renewed"
      (`.claude/rules/no-silent-fallbacks.md`).
- [ ] The refresh request body carries `client_id`, `grant_type=refresh_token` and `refresh_token`
      and **no** `client_secret` and no `code_verifier` — pinned in `SlackOAuthTests`, the same way
      ADR-0012's criterion is pinned.
- [ ] The refresh decision (`due`, `not due`, `no expiry known`, skew boundary) is a pure function
      with its own tests, outside the app target (A3).
- [ ] The refresh token reaches the Keychain and nowhere else, and
      `scripts/check-architecture.sh` fails on a `refreshToken`/`refresh_token` in `UserDefaults`
      or in an interpolated string, exactly as it does for the access token (A4).
- [ ] `Disconnect` deletes the refresh item as well as the token; `make uninstall` removes both.
- [ ] `make doctor` prints when the stored credential expires and whether a refresh token is held;
      `make doctor-slack` after one live reconnect answers cleanly instead of `token_expired`.
- [ ] **Captured, not written:** the real `oauth.v2.access` exchange shape and the real refresh
      shape go into `SlackResponseFixtures` from the live reconnect, with every credential value
      replaced by a placeholder — A4 outranks the verbatim half of
      `.claude/rules/real-data-tests.md`, and the fixture comment says which fields were redacted
      and which are untouched.
- [ ] GAP-0002 records what this measured; it closes only when a credential has survived past its
      own expiry without a human touching it, which is a **next-day** observation and is stated as
      pending until then.

## Affected modules

| Target | Change | Invariants |
|---|---|---|
| `SlackKit` | `SlackCredential`; `SlackWire.credential(_:)` replacing `userAccessToken`; `SlackOAuth.renew`; `TokenRefresh.plan` (pure) | A1, A4 — the kit still stores nothing |
| `OnAir` | `TokenStore` gains the refresh item; `AppCoordinator` refreshes at launch, before a due expiry and once on `token_expired`; `Doctor` reports it | A3 (the *when* is pure and lives in the kit), A4 (`TokenStore` stays the only Keychain door) |
| `scripts/check-architecture.sh` | A4's two greps learn the new credential's name | A4 |
| `docs/` | ADR-0020; GAP-0002 updated; README and `first-run.md` stop saying OnAir has no refresh loop | — |

A3 reading, stated because it is arguable: the refresh *decision* is a pure function with tests, and
it lives in `SlackKit` rather than `StatusKit` because it is about a Slack credential and nothing
about a status. What A3 forbids is a decision in the **app target**, where nothing can assert on it.

## Steps

1. `SlackCredential` + `SlackWire.credential`, with tests for the four shapes: rotating,
   non-expiring, `expires_in` without `refresh_token`, and a refresh response (which may put the
   user token at the top level rather than under `authed_user` — accept both, throw naming both if
   neither).
2. `SlackOAuth.renew` + `renewalBody`, with the no-secret test.
3. `TokenRefresh.plan` — pure: given an expiry, a skew and `now`, is a renewal due? — and its tests.
4. `TokenStore.saveCredential` / `credential()` / `deleteCredential()`; disconnect and
   `make uninstall` clear both items; a token stored by an older build (no refresh item) still
   loads, as a credential with no expiry and no refresh token.
5. `AppCoordinator`: single-flight refresh; run it at `reloadClient`, before a call whose credential
   is due, and once after a `token_expired`; schedule a wake at `expiry - skew`; a refresh that
   fails is a visible `needsReconnect`, never a silent retry loop.
6. `Doctor`: expiry and refresh-token presence in the `Slack` section.
7. `scripts/check-architecture.sh`: `refreshToken|refresh_token` into A4's alternations.
8. ADR-0020, GAP-0002 update, README + `first-run.md`, `docs/index.md` if it lists ADRs.
9. Live: reconnect once, `make doctor-slack`, capture the two shapes redacted into fixtures.

## Risks

- **The refresh response shape is unknown.** Slack documents the bot case; the user case may return
  the token at the top level with `token_type: "user"` or under `authed_user`. Mitigation: accept
  both, throw with both named if neither, and capture the real one at step 9. This is the same class
  of unknown GAP-0001 already tracks.
- **A refresh token is single-use, with a short grace period.** Two concurrent refreshes, or a crash
  between Slack's answer and the Keychain write, burn the chain and cost the user one reconnect.
  Mitigation: single-flight the refresh, and write the new credential before anything else uses it.
- **`expires_in` may arrive as a string.** Accept `Int` and a numeric `String`; anything else
  throws rather than being read as "never expires", which is the reading that would silently
  disable the whole feature.
- **PKCE caps refresh tokens at 30 days.** An app unused for a month still needs a reconnect. That
  is the documented ceiling, not a bug — say so in the README rather than implying "forever".
- **The proof takes a day.** Everything here can be green while the renewal still fails against the
  real endpoint. The criterion that matters is a credential outliving its own expiry unattended, and
  it stays pending in GAP-0002 until observed.

## Decision log

- 2026-08-18 — Refresh in the app rather than registering a new Slack app with rotation off — the
  new-app route needs every existing user to reconnect and leaves OnAir defenceless the next time an
  expiry appears; rotation also cannot be turned off once on, so the escape hatch is one-way.
- 2026-08-18 — The refresh token goes in a second Keychain item rather than beside the access token
  in the existing one — the access token is read on every launch by code that predates this change,
  and a shape change there would strand a working connection on upgrade.
- 2026-08-18 — The renewal item is written **before** the access token. Slack's refresh tokens are
  single-use: a crash between the two writes must lose the *replaceable* half, not the chain.
- 2026-08-18 — `doctor` renews nothing. It is the read-only command, and a diagnostic that rotated
  the credential would change what it was asked to report on. It prints "the app would renew this
  before calling" instead, because `token_expired` from a credential the app would have renewed
  reads as a broken connection when it is not.
- 2026-08-18 — A renewal Slack *refuses* turns the menu red; one that never *reached* Slack backs
  off and retries. The current credential is still valid until its own expiry, so a dropped Wi-Fi
  must not be reported as a disconnection — and a 15-second flat retry against an offline laptop
  would fill a thirty-line history in under eight minutes.
- 2026-08-18 — `make verify` green at 127 tests in 15 suites (from 112 in 13). `swiftlint` still
  skips on this machine — Command Line Tools only, no SourceKit — so lint is CI's word, not this
  run's.
- 2026-08-18 — An empty renewal record is still written. `make doctor` on the machine that reported
  this printed "not needed — Slack issued no expiry" for a credential stored *before* any of this
  existed — a plausible value filling a hole nobody had looked in. `absent` (no item) now reads
  "unknown — stored before OnAir could renew", and `{}` means Slack really did send neither field.
- 2026-08-18 — Two defects found reviewing the diff, both fixed: a successful renewal wrote no
  history line despite the ADR promising one, and two calls that expired together each ran a
  renewal — the second spending the refresh token the first had just minted. A generation counter
  on the credential distinguishes "mine is stale" from "somebody already renewed".
- 2026-08-18 — **Still unmeasured, and the reason this plan is not done:** nothing has renewed
  against the real endpoint. The stored credential predates this change and carries no refresh
  token, so the first measurement needs a human to press Connect once; the second needs the next
  day. Both are in GAP-0002 rather than assumed here.
