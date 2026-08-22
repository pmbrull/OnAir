# ADR-0019 — The callback lands on a page we host

- Status: Accepted
- Date: 2026-08-16
- Supersedes: [ADR-0005](0005-oauth-over-a-self-signed-https-loopback.md),
  [ADR-0016](0016-the-loopback-key-never-touches-a-keychain.md)
- Extends: [ADR-0012](0012-a-public-client-pkce-and-no-secret-anywhere.md)

## Context

Slack's documentation is explicit and ADR-0005 quoted it: *"The `redirect_uri` must use HTTPS… A
Redirect URL must also use HTTPS."* There is no localhost exception. That single sentence is the
root of everything that followed — a TLS listener on loopback, a self-signed certificate for
`localhost`, a shell out to `/usr/bin/openssl` to mint it, a PKCS#12 archive on disk, a
`SecPKCS12Import` to turn it into a `SecIdentity`, and ADR-0016 to stop that import depositing the
private key in the user's login keychain. 268 stranded keys on the machine that found it, most of
them minted by `make verify` itself.

And after all of it, the user still saw a certificate warning. Every single time they connected.
The browser is right to show it: the certificate *is* self-signed. Nothing OnAir can do makes a
warning about an untrusted certificate not appear, short of asking the user to install a root — a
far worse trade.

ADR-0005 named the alternative and rejected it: *"bouncing the callback off a hosted HTTPS page,
which would put a server between the user and their own token."* That rejection was right for the
design of the time and wrong about this one, for a reason ADR-0005 could not have known because
ADR-0012 had not happened yet: **OnAir is a public client, and the code is bound to a verifier that
never leaves the Mac.** A page that sees the authorisation code sees something it cannot use.

## Decision

The Redirect URL registered with Slack is `https://onair.pmbrull.me/callback/` — a static page in
this repository, served by GitHub Pages, with a certificate GitHub provisions.

That page reads `code`, `state` and `error` from its own query string and performs a **top-level
navigation** to `http://127.0.0.1:51234/callback` carrying them. Top-level navigations are not
subject to mixed-content rules, so the hop from an HTTPS page to a loopback HTTP listener is one
every current browser makes without complaint.

Therefore:

- **The loopback listener speaks plain HTTP.** `LoopbackIdentity` is deleted: no certificate, no
  `/usr/bin/openssl`, no PKCS#12, no `SecPKCS12Import`, and nothing that can strand a key.
- **The page lives in this repository**, not on the personal site, because the port, the path and
  the shape of `state` are OnAir's. Invariant **A7** fails the build if they disagree.
- **Invariant A6 is restated, not retired.** It was "`SecPKCS12Import` must pass
  `kSecImportToMemoryOnly`"; it is now "OnAir imports no PKCS#12 archive at all". Strictly
  stronger, and it exists to catch a *reintroduction*.
- **The page is plain HTML and JavaScript with no build step.** What is served is what is in the
  repository, and there is no lockfile that can turn a login into a supply-chain question.

## Consequences

**The good.** No certificate warning. A user connects, approves, and lands back in the menu bar.
Three files and roughly 300 lines of certificate machinery are gone, along with the class of bug
that ADR-0016 existed to prevent — and `make verify` stops being the biggest polluter of the
developer's own login keychain.

**The cost, stated plainly: the authorisation code now passes through infrastructure we do not
own.** It arrives in the query string of a request to GitHub's edge and appears in its access logs.
This is a real change in exposure and it is why this is an ADR and not a commit message. What makes
it acceptable rather than merely tolerable:

- The code is useless alone. PKCE (ADR-0012) binds it to a verifier generated on the Mac for this
  attempt and never transmitted anywhere but Slack's token endpoint.
- It is single-use, short-lived, and Slack binds it to the `redirect_uri` it was issued for.
- The page is static. There is no server-side code, no storage, no analytics and no third-party
  script — nothing that *could* keep it beyond a log line.
- It carries `noindex` and `no-referrer`, so the URL is neither indexed nor forwarded onward.
- The token itself never goes near it: the exchange is a direct POST from the Mac to Slack.

**The second cost: connecting now depends on a domain and a deploy.** If `onair.pmbrull.me` stops
resolving, nobody can connect — an installed, connected OnAir keeps working, but a new connection
fails. Before this, connecting depended on nothing but the machine it ran on. That is the trade:
one external dependency on a path taken once per user, against a warning on that same path every
time.

That cost was paid on 2026-08-22, and it came due before anyone had connected once: the domain and
the Slack app both still had to be told about the move, and neither is something this repository can
do. [`docs/runbooks/callback-domain.md`](../runbooks/callback-domain.md) is that procedure — the DNS
record, the repository's custom-domain setting (which `site/CNAME` does *not* perform on a
workflow-built Pages site) and the Slack registration, in the order that makes each failure legible.

**A third, smaller one: the page and the app must stay in step.** A page that hands back to the
wrong port fails a login with an error that names neither. Hence A7, and hence the page shipping
from this repository rather than beside the blog.

## Alternatives

**Keep the self-signed listener (ADR-0005, status quo).** Rejected: it is the warning. Everything
else about it was fine.

**Ship a real certificate for `localhost`.** Certificate authorities do not issue for `localhost`,
and one that did would be issuing a certificate whose private key ships to every user — the
`localhost:5000` incidents are what that looks like when it goes wrong.

**Ask the user to trust OnAir's certificate once.** Installing a root, or a login-keychain trust
setting, to remove a warning is a much larger ask than the warning is a problem — and ADR-0016 is
the record of what OnAir writing to the login keychain costs.

**A custom URL scheme (`onair://callback`).** Slack requires HTTPS; a custom scheme cannot be
registered at all. It also cannot be reserved, so any app can claim it.

**The device-code flow.** Slack does not offer one for user tokens.

**Host the page on the personal site (`pmbrull/coffee`, Vercel).** Built and measured first, and it
worked. Rejected because the contract the page implements is OnAir's: hosting it in another
repository means a port change in one repository and a page change in another, with a broken login
in between and no check that could see it.

**A dynamic redirect endpoint** — a small function that 302s to the loopback instead of a page that
navigates. Rejected: it turns a static file into a service to run, and an open redirector is one
missing validation away. The page hardcodes `127.0.0.1` as its target host, which a query-driven
redirector could not.
