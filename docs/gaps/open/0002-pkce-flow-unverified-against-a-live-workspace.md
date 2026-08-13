---
id: GAP-0002
title: The PKCE flow and its token longevity are unverified against a live workspace
status: open
impact: two documented-but-unmeasured claims sit under the whole connect flow
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

**Blocks.** The claim "connect works end to end". If (1) is wrong, every connect fails at the
exchange with a Slack error — loud, at least. If (2) is wrong, tokens die after 30 days and OnAir
needs a refresh-token loop it does not have; the failure mode is `token_expired`, which the menu
already surfaces as "Reconnect Slack", so it degrades to an inconvenience rather than a silence.

**Provisional handling.** Built to the PKCE walkthrough's letter. Close by: create the shared app
with PKCE on, `make doctor-slack` after a real connect, note the endpoint that answered and —
after 30 days, or by checking `oauth.v2.access`'s response for `expires_in` — whether the token
carries an expiry. Record the verbatim exchange response into `SlackResponseFixtures` while there
(that also shrinks GAP-0001).
