# Runbook — the callback domain (maintainer, once ever)

The half of ADR-0019 that no workflow can do. `site/` deploys itself on every push, but the domain
it is *served under* lives in two places outside this repository — a DNS zone and a repository
setting — and until both are set, `https://onair.pmbrull.me/callback/` does not exist. Slack's
redirect URL is that string, so nobody can connect.

Done **once for the lifetime of the domain**. Ordering matters throughout, and not only for
convenience: §0 before §1 closes a takeover window, and §1 before §2 is what lets GitHub issue a
certificate.

Starting from nothing, this runbook interleaves with [`shared-app.md`](shared-app.md): do §0–§2
here, then all of `shared-app.md`, then §3 here — which needs the app that runbook creates.

## What it looks like when it is missing

Two distinct failures, both seen on 2026-08-22 before the first successful connect, and they arrive
in the opposite order to the one you fix them in.

The Slack authorise page refuses before the browser is sent anywhere:

> redirect_uri did not match any configured URIs. Passed URI: https://onair.pmbrull.me/callback/

That is the *Slack app* not carrying the URL (§3), and it is independent of DNS — Slack never
fetches the redirect URL, it compares strings. Fix it last, because fixing it first means the
browser sails past Slack and lands on a dead domain instead, which is harder to read.

And, from the machine:

```
$ dig +short onair.pmbrull.me
                                        # nothing — §1 not done
$ curl -sSI https://onair.pmbrull.me/callback/
curl: (60) SSL: no alternative certificate subject name matches target host name
                                        # DNS resolves but §2 not done
```

The second reads as "broken TLS" and, **before §2 has ever succeeded**, is not: DNS points at
GitHub's edge, GitHub has not been told which repository owns that hostname, so it answers with the
certificate for `*.github.io`. Once §2 has succeeded, the same output means something else entirely
— see §4.

## 0. Verify the parent domain, before the subdomain resolves

GitHub's edge routes Pages on the `Host:` header, and a CNAME's target is not tied to the account
that owns the repository. So any hostname that **resolves to Pages but that no repository has
claimed** can be claimed by any GitHub user — and they get a valid Let's Encrypt certificate for it.

For an ordinary project page that is defacement. Here the hostname *is* Slack's registered redirect
URL, so whoever holds it receives `code` and `state` for every connect, and can forward to the
loopback so the login still succeeds while they log everything. PKCE keeps the code unusable — the
verifier never leaves the Mac (ADR-0012) — but not the logging, not the denial of every new
connection, and not the phishing surface at the exact URL [`first-run.md`](first-run.md) tells users
to expect.

Account-level verification closes it for the whole zone, including subdomains that do not exist yet:

github.com → **Settings** → **Pages** → **Add a domain** → `pmbrull.me` → add the
`_github-pages-challenge-pmbrull` TXT record it names → **Verify**.

Do it **before** §1, so the window never opens. `protected_domain_state` in §4 is how you check it
stuck.

## 1. DNS

At the registrar holding the zone — Porkbun, for `pmbrull.me`:

| Type | Host | Answer | TTL |
|---|---|---|---|
| `CNAME` | `onair` | `pmbrull.github.io` | 600 |

The answer is the **user** Pages host, not the project URL: no `/OnAir`, no repository name. The
apex `A` record (a different site entirely) is untouched.

```bash
dig +short onair.pmbrull.me
# pmbrull.github.io.
# 185.199.108.153 … 185.199.111.153
```

**Several subdomains may share that one answer**, and this zone already does — `claustre.pmbrull.me`
resolves identically. The `Host:` header is what separates them. The rule that *does* bite is the
other direction: one domain, one repository. Two repositories cannot claim the same string.

## 2. Tell the repository it owns the host

**`site/CNAME` does not do this.** The file exists, it contains `onair.pmbrull.me`, and
`scripts/check-architecture.sh` requires it to match `SlackOAuth.redirectURI` (invariant A7) — but
Pages here is built by a workflow (`build_type: workflow`), and for workflow-built sites GitHub
ignores the CNAME file in the artefact. It declares the domain; the setting below is what serves it.

```bash
gh api -X PUT repos/pmbrull/OnAir/pages -f cname=onair.pmbrull.me
```

Or Settings → Pages → Custom domain. Either way GitHub re-checks DNS and orders a certificate, which
is why §1 comes first. Measured 2026-08-22: Let's Encrypt issued `CN=onair.pmbrull.me` about seven
minutes after the claim.

This `PUT` is a **partial update**, measured the same day: `build_type` and `source` were unchanged
by a `cname`-only call. So `https_enforced` can be set on its own once the certificate exists.

```bash
for _ in $(seq 40); do
    curl -sSI https://onair.pmbrull.me/callback/ 2>/dev/null | head -1 | grep -q 200 && break
    sleep 30
done
gh api -X PUT repos/pmbrull/OnAir/pages -F https_enforced=true
```

Twenty minutes without a `200` means the claim did not take, not that the certificate is slow:
re-read §4's `cname` field before waiting longer.

## 3. Register the URL with Slack

Needs the app from [`shared-app.md`](shared-app.md) §1, so it lands after that runbook rather than
before it.

App dashboard → **OAuth & Permissions** → **Redirect URLs** → add
`https://onair.pmbrull.me/callback/` → **Save URLs** (a separate button below the list; adding alone
does not save), and remove the pre-ADR-0019 `localhost` entries. An app created from the README's
manifest link already carries it; an app created before ADR-0019 does not, and that is the error at
the top of this page.

The **trailing slash is load-bearing** and Slack compares the string byte for byte, twice — once on
the authorise page and again at the token exchange (`SlackOAuth.exchangeBody` re-sends it).
`SlackOAuth.redirectURI` is the canonical spelling; the lifecycle table below lists the copies that
have to follow it by hand.

Editing the URL in place is the right tool here, not pasting the README manifest: the manifest asks
for `token_rotation_enabled: false`, the shared app rotates anyway (ADR-0020), and Slack does not
let rotation be turned off once it is on.

## 4. What "done" looks like

```bash
gh api repos/pmbrull/OnAir/pages --jq '{cname,https_enforced,protected_domain_state,build_type}'
# {"cname":"onair.pmbrull.me","https_enforced":true,"protected_domain_state":"verified","build_type":"workflow"}

curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://onair.pmbrull.me/callback/
# 200
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://pmbrull.github.io/OnAir/callback/
# 301 https://onair.pmbrull.me/callback/
```

`protected_domain_state` is the only field that reports §0; `cname` and `https_enforced` read
identically whether the domain is verified or not. `build_type` must stay `workflow` — branch
publishing would serve the repository root, where `/callback/` does not exist.

That last redirect is the tell that the claim landed: the project-path URL stops serving and starts
pointing at the custom domain. Nothing in this repository changes.

**After this has succeeded once, a certificate-name mismatch on this host is an incident, not a
wait.** It means something other than this repository is answering for Slack's redirect URL.

Then one live **Connect to Slack**, which is the criterion no check here can fake.

## Lifecycle afterwards

| Event | Action needed |
|---|---|
| New OnAir release | none — the domain is not per version |
| `site/` changes | none — `pages.yml` redeploys; the domain claim survives |
| Certificate expiry | none — GitHub renews it |
| Domain or DNS changed | re-run §4, `https_enforced` included — it can revert when Pages re-provisions |
| Retiring the domain | **remove the DNS record first, then the repository claim.** The reverse order leaves a hostname resolving to Pages that nobody owns, which is §0's window held open deliberately |
| Domain moves | §0–§3 again, plus every copy of the URL below |

A7 holds `SlackOAuth.redirectURI` and `site/CNAME` together, and nothing else. These copies are
manual, and a domain move leaves every one of them stale with a green gate: `README.md` (the JSON
manifest, the prose, and the percent-encoded `manifest_json` link), the same encoded link in
[`first-run.md`](first-run.md) and [`shared-app.md`](shared-app.md), `docs/dev-loop.md`, `CLAUDE.md`,
`.github/workflows/pages.yml`, `Sources/SlackKit/OAuth/LoopbackReceiver.swift` and
`Tests/SlackKitTests/SlackOAuthTests.swift`. GAP-0004 carries the fact that A7 cannot see any of
them, nor the live Pages setting.
