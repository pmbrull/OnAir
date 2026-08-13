# ADR-0012 — A public client: PKCE, one shared app, no secret anywhere

- Status: Accepted
- Date: 2026-08-13
- Amends: ADR-0005 (the loopback survives; the pasted credentials do not)

## Context

ADR-0005 made the user create their own Slack app and paste its client id **and secret** into
Settings. That was the honest shape available under classic OAuth: the only alternatives were
shipping a secret in the binary (extractable, and a phishing kit with OnAir's name on it) or
pasting a raw token (same console trip, a live credential through the clipboard).

The setup burden was the complaint: every user visits api.slack.com, configures scopes and a
redirect URL, and pastes two values before anything works. In the middle of arguing B against C,
the actual answer surfaced: **Slack supports PKCE (RFC 7636)**, and its documentation says plainly
that with PKCE "the client should not include `client_secret` in the parameters."

## Decision

OnAir is a **public client**:

- One Slack app, created once by the maintainer, PKCE enabled. Its **client id ships in the
  binary** (`SlackOAuth.builtInClientID`) — a public identifier by design, visible in every
  authorize URL Slack has ever emitted. **No secret exists anywhere in the system.**
- Connect generates a fresh verifier (32 CSPRNG bytes), sends its S256 challenge on the authorize
  URL, and proves possession of the verifier at `oauth.v2.access`. An intercepted code is useless
  without the in-process verifier.
- The token still lands in the Keychain and nowhere else — A4 is unchanged in force and narrower
  in scope, since the secret it used to police no longer exists.
- Until the shared app is registered, `builtInClientID` is empty and Settings shows a single
  Client ID field; a pasted id also *overrides* the built-in one permanently, which is the escape
  hatch for a workspace that blocks the shared app.

The TLS loopback and its self-signed certificate stay. PKCE would make a hosted HTTPS redirect
page safe (the intercepted-code risk it carried is gone), and that is the recorded path to
removing the browser warning — but it is a separate change with its own hosting question, not
this one.

## Consequences

- **User setup collapses to one click.** Install → Connect → Authorize. No Slack console, no
  fields. This is the best possible answer to both axes of the question that prompted it — quick
  setup *and* distribution security — simultaneously, because removing the secret removed the
  thing both problems were made of.
- Enabling PKCE marks the Slack app a **public client, one-way** (undo requires Slack support).
  Hence a dedicated app for OnAir, never a flag flipped on an app that has other duties.
- Slack's docs read as: tokens stay non-expiring with an https redirect and token rotation off —
  which is our configuration. Unverified against a live workspace, so it is **GAP-0002**, not a
  fact. If it proves wrong, this ADR grows a refresh-token loop.
- The exchange endpoint under PKCE is `oauth.v2.access` per Slack's own PKCE walkthrough; one
  reference page also names `oauth.v2.user.access`. If a live connect refuses, check that first
  (also GAP-0002).
- Workspaces with admin approval for apps still gate the install. True of every shape; nothing to
  do about it here.
- **The one capability the deleted secret provided is gone: distinguishing OnAir from other
  software on this machine.** Local malware can bind the port while OnAir is idle, drive the
  browser through Slack's consent screen under OnAir's name with its own PKCE pair, and mint a
  token off one plausible Approve click. The registered redirect pins that attack to localhost —
  it cannot be mounted remotely — and it is the standard RFC 8252 public-client trade, but it is
  a trade, and this is its record.

## Alternatives rejected

- **Ship the secret** — extractable from any downloaded copy; not a secret.
- **Paste a token** — saves nothing: the console trip, which is the actual cost, remains.
- **Keep ADR-0005's pasted pair** — strictly dominated by this once PKCE exists.
