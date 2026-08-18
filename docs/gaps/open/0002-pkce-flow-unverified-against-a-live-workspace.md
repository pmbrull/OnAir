---
id: GAP-0002
title: The PKCE flow and its token longevity are unverified against a live workspace
status: open
impact: the credential expires (measured), and the renewal that answers it is untested against Slack
opened: 2026-08-13
closed_by:
---

**Question.** Two things Slack's documentation asserts and nothing here has measured:

1. Does `oauth.v2.access` accept a PKCE exchange (`client_id` + `code` + `code_verifier`, no
   secret)? Slack's PKCE walkthrough uses this endpoint, but a reference page also names
   `oauth.v2.user.access`, and the two claims have never been reconciled against a live app.
2. Is the user token **non-expiring** in our configuration — https loopback redirect, token
   rotation off, PKCE on? The docs read that way ("Slack will always issue a rotating token" is
   scoped to *custom URI* redirects; the 30-day expiry is scoped to refresh tokens), but the
   sentence structure is exactly the kind a plausible misreading survives.

**Why it's open.** No Slack app with PKCE enabled existed when the flow was built. The transform
itself is pinned to the RFC 7636 appendix-B vector, and the request shape to tests — but a test of
our own encoding proves our encoding, not Slack's acceptance of it (`.claude/rules/real-data-tests.md`).

**Blocks.** The claim "a connection made once keeps working". (1) is answered. (2) turned out to be
wrong in the direction that costs the user a login every morning, which is why ADR-0020 exists; what
is left is whether the renewal loop that answers it works against the real endpoint. If it does not,
the failure mode is the one that was already there — `token_expired`, surfaced as "Reconnect Slack"
— so this degrades to the previous inconvenience rather than to a silence.

**Measured so far (2026-08-13, `make doctor-slack` against Collate).** A stored user token answered
`auth.test` and `users.profile.get`. That token can only have come from the OAuth session —
`TokenStore` is written from exactly one place — and `SlackOAuth` posts the exchange to exactly one
endpoint, so **question (1) is answered**: `oauth.v2.access` accepts a PKCE exchange with no secret,
in this configuration.

**Question (2) is answered, and the answer is the bad one (2026-08-18).** The same credential, five
days later:

```
  user credential       present in the Keychain
  Slack refused the call: token_expired
```

The credential **expires**. `token_expired` is what a rotating token answers past its twelve hours,
so the plan behind ADR-0012 — "non-expiring with an https redirect and rotation off" — does not
describe what this app actually issues. Whether that is `token_rotation_enabled` being on despite
the manifest, or an expiry imposed some other way, is **not** decidable from here: nothing in this
repository can read that toggle.

**Handling (ADR-0020).** OnAir now stores `expires_in` and `refresh_token` and renews the credential
itself, which is correct under either cause. Two things remain unmeasured, and they are what keeps
this gap open:

1. **The renewal response's shape for a *user* token.** Slack documents it for bot tokens, at the
   top level; the parser accepts that and the `authed_user` wrapping, and neither has been seen.
2. **That renewal actually works end to end.** Every test can pass while the real call fails.

**Close by:** connect once, then run `make doctor-slack` again the following day without touching
anything. A clean answer past the original expiry closes this. Capture the exchange and the renewal
into `SlackResponseFixtures` with both credential values replaced by placeholders — A4 outranks the
verbatim half of `.claude/rules/real-data-tests.md` — which also shrinks GAP-0001.
