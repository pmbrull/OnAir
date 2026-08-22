# Plan 0009 — A hosted callback, and a plain loopback

- Status: Active
- Date: 2026-08-16
- Input: [ADR-0005](../../decisions/0005-oauth-over-a-self-signed-https-loopback.md) and
  [ADR-0016](../../decisions/0016-the-loopback-key-never-touches-a-keychain.md) — both of which
  exist only because Slack refuses an `http://` redirect URL, and both of which this plan retires.

## Goal

Connecting to Slack stops showing a certificate warning. Slack's redirect URL becomes
`https://onair.pmbrull.me/callback/` — a real origin with a real certificate, served as static
files by GitHub Pages out of this repository — and that page hands `code` and `state` back to
OnAir with a top-level navigation to `http://127.0.0.1:<port>/callback`. Top-level navigations are
not subject to mixed-content rules, so the loopback listener no longer needs TLS: no self-signed
certificate, no `/usr/bin/openssl`, no `SecPKCS12Import`, and nothing that can strand a key in
anyone's login keychain. `LoopbackIdentity` is deleted rather than left unused.

The relay page lives *in this repository* precisely because the contract it implements — the port,
the path, the shape of `state` — is OnAir's. Hosting it beside the app means the two can never
drift into a version where the page hands back to a door the app is not standing behind.

## Acceptance criteria

- [x] `make verify` is green.
- [x] `scripts/check-architecture.sh` fails a tree in which `SecPKCS12Import` appears anywhere.
      A6 is restated, not dropped: OnAir imports no PKCS#12 archive at all, which is strictly
      stronger than the old "must pass `kSecImportToMemoryOnly`".
- [x] `LoopbackIdentity.swift` and its tests are gone, and nothing in `Sources/` or `Tests/`
      mentions it.
- [x] `LoopbackTests` drives the plain-HTTP listener with `URLSession` and still covers: the happy
      path, `?error=`, a mismatched `state`, a non-callback path, and a malformed request.
- [x] The relay is measured, not reasoned about: a browser loaded with a callback URL reaches a
      listener on the loopback port with `code` and `state` intact, for the default port and for a
      port carried in `state`.
- [x] And measured **from an HTTPS origin**, in Chromium, WebKit and Firefox — the first pass served
      the page over `http://`, which did not exercise the one property the design rests on.
- [x] `https://onair.pmbrull.me/callback/` serves the relay over a valid certificate, and
      `https://onair.pmbrull.me/` serves a landing page. Measured 2026-08-22: both answer `200`,
      the certificate is Let's Encrypt `CN=onair.pmbrull.me`, and `pmbrull.github.io/OnAir/callback/`
      now `301`s to it. The two steps this needed were the human ones — the DNS record and the
      repository's custom-domain setting, neither of which `site/CNAME` performs on a
      workflow-built site. [`docs/runbooks/callback-domain.md`](../../runbooks/callback-domain.md).
- [ ] One live **Connect to Slack** completes end to end with no certificate warning, against a
      real workspace. This is the criterion that cannot be faked and it is measured by a human.
- [x] `make doctor` prints the hosted redirect URL.

## Affected modules

| Target | Change | Invariants |
|---|---|---|
| `SlackKit` | `SlackOAuth.redirectURI` returns the hosted URL; `LoopbackReceiver` drops TLS; `LoopbackIdentity` deleted | **A6** restated; A1/A2 untouched — still no AppKit, still no reverse dependency |
| `OnAir` (app) | `AppCoordinator` loses the `LoopbackIdentity.Failure` catch; Settings copy about the warning is now false | A3 — no decision moves into the app |
| `site/` (new) | Static relay + landing page, deployed by `.github/workflows/pages.yml` | none — not a Swift target |
| `scripts/check-architecture.sh` | A6 restated | — |

The relay page is plain HTML, CSS and JavaScript with no build step. ADR-0004 is about the app's
dependencies and does not bind a static page, but a repository that fetches nothing to build
itself is worth keeping; the deploy workflow uploads a directory.

## Steps

1. **The page, first, because it is the thing that can be measured on its own.** `site/index.html`
   (landing), `site/callback/index.html` (relay), `site/CNAME`. Drive it with a real browser
   against a real listener before any Swift changes.
2. **Deploy it.** `.github/workflows/pages.yml` on the claustre pattern — `pages: write`,
   `id-token: write`, `upload-pages-artifact` over `site/`, `deploy-pages`. Enable Pages on the
   repository and set the custom domain.
3. **DNS.** `onair` CNAME → `pmbrull.github.io` at Porkbun. Not something this repository can do;
   it is a step for the human, and until it lands the page answers on `pmbrull.github.io/OnAir`.
4. **`SlackOAuth.redirectURI`** returns `https://onair.pmbrull.me/callback/`. The same string
   goes to the authorize URL and the token exchange — Slack compares them.
5. **`LoopbackReceiver` drops TLS.** `NWListener` with plain `NWParameters.tcp`, no identity
   argument, and the `identityUnusable` failure case goes with it.
6. **Delete `LoopbackIdentity`**, its tests, and the `LoopbackIdentity.Failure` catch in
   `AppCoordinator`.
7. **Restate A6** in `scripts/check-architecture.sh` and `ARCHITECTURE.md`.
8. **Fall back when the port is taken.** With a relay in front, a busy 51234 is recoverable: bind
   any free port and append `.<port>` to `state`, which the page reads and the receiver compares
   whole. This is the one step that may be dropped without weakening the rest.
9. **Docs.** ADR-0019 superseding 0005 and 0016; `README.md`'s manifest (the redirect URL appears
   twice, once URL-encoded); `CLAUDE.md`'s list of things that trip you up; `SettingsSlackPane`'s
   sentence about the warning; `ARCHITECTURE.md`.
10. **Slack app.** Redirect URL replaced at api.slack.com. Also a step for the human.

## Risks

- **The old redirect URL stops working the moment Slack's config changes, and the new one does not
  work until DNS and Pages both land.** Order matters: page live and answering on the custom
  domain *before* the Slack app is edited, and a build carrying the new `redirectURI` before
  anyone tries to connect. Caught by loading `https://onair.pmbrull.me/callback/` in a browser
  before touching Slack.
- **The authorisation code passes through GitHub's edge**, and appears in its access logs. It is
  useless there: the PKCE verifier never leaves the Mac, the code is one-time and Slack binds it to
  the `redirect_uri`. The page adds `no-referrer` and `noindex` because both are free. This is a
  real change in exposure and it is the reason ADR-0019 exists rather than a commit message.
- **A browser that refuses the `https:` → `http://127.0.0.1` hop** would break connecting for
  everyone on it — and on macOS, Safari refusing it would break it for most people. **Measured on
  2026-08-16 in all three engines**, driving the real page served over real TLS: Chromium, WebKit
  and Firefox each performed the navigation and the loopback listener received `code` and `state`
  intact. Mixed-content rules apply to subresources, not to top-level navigations, and loopback is
  exempt from HTTPS-First upgrading in all three. The page also keeps a visible fallback link for
  an engine that surprises us anyway.

  Worth recording from the same run: **Firefox then fetched `/favicon.ico` against the loopback
  listener.** That is exactly the request `faviconDoesNotEndTheWait` exists for, arriving unprompted
  from a real browser rather than from a test.
- **Trailing slash.** `https://onair.pmbrull.me/callback` without the slash is a 301 on GitHub
  Pages. Registering the slashed form with Slack sidesteps the question entirely; the unslashed
  form is checked anyway, because a human will type it.

## Decision log

- 2026-08-16 — The page lives in this repository, not in the personal site — Because the port, the
  path and the shape of `state` are OnAir's, and a page that drifts from them fails a login with no
  error anyone can read. Hosting it in `pmbrull/coffee` was built and measured first; it worked,
  and was reverted for this reason.
- 2026-08-16 — Static HTML, no Astro — claustre's docs site is Astro because it is a docs site.
  This is two pages, one of which must keep working when JavaScript is the only thing that runs.
  A build step would add a way for it to break without adding anything it needs.
- 2026-08-16 — A6 is restated rather than retired — `SecPKCS12Import` disappearing from the tree is
  the point; a check that fails when it comes back is cheaper than remembering why it left.
- 2026-08-16 — **Step 8 dropped.** Binding a fallback port means binding *before* the state is
  built, because the port has to be inside the state before the browser opens — and `LoopbackReceiver`
  binds inside `waitForCallback`. Probing for a free port first would be a TOCTOU race dressed as
  robustness, and restructuring the bind order is a second change wearing this one's clothes. A
  taken 51234 already reports itself with a readable sentence rather than failing silently, which
  is what `.claude/rules/no-silent-fallbacks.md` actually asks for. The page keeps the `.<port>`
  capability, so the app can start using it later with no redeploy.
- 2026-08-16 — **A7 was added, and the drift check moved out of the workflow into it.** The first
  draft put the port comparison in `pages.yml`, which meant the check only ran on deploy and only
  in CI. As an invariant it runs in `make verify`, in the pre-commit hooks, in the gate *and* in
  the deploy, and it says what it is protecting. Negative-tested both ways before trusting it: a
  drifted port and a drifted domain each fail it, and restoring each returns it to green.
- 2026-08-16 — **GAP-0003 closed, without being answered.** The unexplained keychain deposit asked
  whether a second path into the login keychain existed. Deleting the import makes the question
  unanswerable and irrelevant at the same time; the record says so in those words rather than
  claiming a resolution. `make purge-loopback` reporting zero on this machine is noted as
  consistent-with, not proof-of.
- 2026-08-16 — **The README's security claim was wrong the moment this landed**, and rewriting it
  was not optional: it said the authorisation code *never leaves your machine*. It now does. The
  paragraph says what passes through the page, what the page cannot do with it, and that the token
  is never on that side of the wire at all.
- 2026-08-22 — **The domain was the last mile, and `site/CNAME` does not walk it.** The first real
  connect failed at Slack's authorise page — `redirect_uri did not match any configured URIs` — and
  behind that sat two steps no workflow here can take: no DNS record for `onair.pmbrull.me` at all,
  and no custom domain claimed on the repository. Pages is workflow-built, so GitHub ignores the
  CNAME file in the artefact: it declares the host and A7 checks the declaration, but the repository
  setting is what serves. Written up as
  [`docs/runbooks/callback-domain.md`](../../runbooks/callback-domain.md) rather than left in a
  commit message, because it is due again the day the domain moves — and the gate was green the
  whole time, which is [GAP-0004](../../gaps/open/0004-a7-cannot-see-what-pages-actually-serves.md).
