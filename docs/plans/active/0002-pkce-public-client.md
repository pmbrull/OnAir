# Plan 0002 — PKCE: one shared Slack app, no secret anywhere

- Status: Active
- Date: 2026-08-13
- Input: ADR-0005 (superseded in part), the "cumbersome setup" conversation, Slack's
  [Using PKCE](https://docs.slack.dev/authentication/using-pkce/) documentation

## Goal

A user installs OnAir, presses Connect, sees Slack's "Authorize" page, and is done — no visit to
api.slack.com, no fields to paste. The binary ships only a `client_id`, which is public by design;
the client secret ceases to exist in this system entirely. PKCE (RFC 7636) is what makes the
authorisation code useless to an interceptor without a secret. The token still lands in the
Keychain and nowhere else (A4, unchanged).

## Acceptance criteria

- [x] `make verify` is green.
- [x] `oauth.v2.access` is called with `code_verifier` and **without** `client_secret`; the
      authorize URL carries `code_challenge` + `code_challenge_method=S256`. Pinned by tests
      including the RFC 7636 appendix-B vector.
- [x] No `clientSecret` identifier survives anywhere in `Sources/` (grep = empty — the legacy
      decoder recognises the old shape without declaring the field, since `Decodable` ignores
      unknown keys).
- [x] Settings shows **no credential fields** when a client id is baked in, and exactly one
      (Client ID) when it is not — never a secret field.
- [x] A token stored by the previous build still connects (the `slack-token` item is untouched),
      and the legacy client item's decode is pinned by `parseStoredClientID` tests; the Keychain
      write itself gets one manual upgrade check (see Risks).
- [x] ADR-0012 records the decision; ADR-0005's status line points at it.
- [ ] Live verification (blocked on the Slack app existing): connect against a real workspace via
      `make doctor-slack`, and record whether the token is non-expiring — GAP-0002 tracks it.

## Affected modules

`SlackKit` (OAuth only — wire parsing untouched), `OnAir` (Settings, TokenStore, coordinator,
doctor). Invariants: **A4** unchanged in force, narrowed in scope (one credential now, not three);
**A2/A1** untouched. `StatusKit`, `DeviceKit` untouched.

## Steps

1. `PKCE` type in `SlackKit`: verifier from `SecRandomCopyBytes` (32 bytes → base64url, 43 chars),
   challenge = base64url(SHA256(verifier)) via CryptoKit. Test with the RFC 7636 vector.
2. `SlackOAuth`: challenge params on the authorize URL; exchange sends
   `client_id, code, code_verifier, redirect_uri`; `Credentials` struct → plain `clientID: String`.
   `SlackOAuth.builtInClientID` constant (empty until the shared app exists).
3. `TokenStore`: `slack-client` item now stores the id override as a plain string; decode the old
   JSON `{clientID, clientSecret}` on read and keep only the id.
4. App: Settings Slack pane loses both fields (gains one, shown only when no built-in id);
   coordinator and doctor read the resolved client id; setup instructions rewritten for the two
   audiences (app author once, everyone else never).
5. Docs: ADR-0012; ADR-0005 amended; GAP-0002 (token longevity under PKCE unverified); README,
   runbook, CLAUDE.md, profile.
6. `make verify`, review panel on the diff, push to the open PR.

## Risks

- **The exchange endpoint under PKCE.** Slack's PKCE doc shows `oauth.v2.access`; one reference
  page also names `oauth.v2.user.access`. Going with the PKCE doc's own flow; if a live connect
  refuses, that is the first thing to check. Recorded in GAP-0002 rather than guessed flat.
- **Token expiry.** Docs read as: non-expiring unless rotation is on or the redirect is a custom
  URI scheme. Ours is https loopback with rotation off. Unverifiable without the live app —
  GAP-0002.
- **Old Keychain item shape.** The decode (legacy JSON vs plain string) is pure, lives in
  `SlackKit.parseStoredClientID`, and is pinned by tests against the verbatim old JSON. The
  Keychain rewrite around it is app-target code with no test target — it runs at every launch
  (`scrubLegacyClientItem`), reports failure to the menu instead of swallowing it, and gets one
  manual check by upgrading a connected pre-ADR-0012 install.

## Decision log

- 2026-08-13 — Ship only the client id; PKCE replaces the secret — Slack's own docs: "the client
  should not include `client_secret` in the parameters" when PKCE is used. Kills both the pasted
  fields and the extractable-secret problem in one move.
- 2026-08-13 — Keep the TLS loopback and its certificate — PKCE would make a hosted redirect page
  safe, but that is a separate change with its own trade-offs; not both at once.
- 2026-08-13 — `SlackOAuth.builtInClientID` is a source constant, not a build flag — one line to
  edit when the shared app exists, and Settings degrades to a single visible field until then, so
  the app stays fully usable before the constant is filled. (Landed on `SlackOAuth` rather than a
  separate type: the OAuth surface already has one home, and a second enum holding one string was
  ceremony.)
- 2026-08-13 — Review panel (all five) on the diff. The finding that reshaped the change: the id
  precedence rule sat as a free function in the untested app target and Doctor had a second,
  divergent copy — an A3 violation caught by `architecture-reviewer`. Hoisted to
  `SlackOAuth.resolveClientID` + `ClientIDSource` with tests; Doctor and the app now render one
  rule. Also from review: the legacy-secret scrub now runs at every launch (the common upgrade
  path never read the item lazily) and reports failure; `LegacyCredentials.clientSecret` deleted
  (`Decodable` ignores unknown keys); `verifier` added to the A4 greps; a pasted override
  shadowing the built-in id is surfaced in Settings with a "Use built-in" way back; ADR-0012
  records the RFC 8252 residual risk.
