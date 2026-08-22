# Runbook — the callback domain (maintainer, once ever)

The half of ADR-0019 that no workflow can do. `site/` deploys itself on every push, but the domain
it is *served under* lives in two places outside this repository — a DNS zone and a repository
setting — and until both are set, `https://onair.pmbrull.me/callback/` does not exist. Slack's
redirect URL is that string, so nobody can connect.

Done **once for the lifetime of the domain**. Ordering matters and the steps verify each other.

## What it looks like when it is missing

Two distinct failures, and they arrive in the opposite order to the one you fix them in.

The Slack authorise page refuses before the browser is ever sent anywhere:

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

The second one is the state that reads as "broken TLS" and is not: DNS points at GitHub's edge,
GitHub has not been told which repository owns that hostname, so it answers with the certificate
for `*.github.io`.

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
resolves identically. GitHub's edge routes on the `Host:` header, not on DNS: each repository claims
one custom domain in §2, and the edge maps an incoming host to the repository claiming it. The rule
that *does* bite is the other direction — one domain, one repository. Two repositories cannot claim
the same string.

## 2. Tell the repository it owns the host

**`site/CNAME` does not do this.** The file exists, it contains `onair.pmbrull.me`, and
`scripts/check-architecture.sh` requires it to match `SlackOAuth.redirectURI` (invariant A7) — but
Pages here is built by a workflow (`build_type: workflow`), and for workflow-built sites GitHub
ignores the CNAME file in the artefact. It documents the intent; the setting below is what serves.

```bash
gh api -X PUT repos/pmbrull/OnAir/pages -f cname=onair.pmbrull.me
```

Or Settings → Pages → Custom domain. Either way GitHub re-checks DNS and orders a certificate, which
is why §1 comes first. Measured 2026-08-22: Let's Encrypt issued `CN=onair.pmbrull.me` about seven
minutes after the claim.

Wait for it, then enforce HTTPS — the `cname` is resent because this endpoint replaces the
configuration and omitting it can clear the domain:

```bash
until curl -sSI https://onair.pmbrull.me/callback/ 2>/dev/null | head -1 | grep -q 200; do sleep 30; done
gh api -X PUT repos/pmbrull/OnAir/pages -f cname=onair.pmbrull.me -F https_enforced=true
```

## 3. Register the URL with Slack

App dashboard → **OAuth & Permissions** → **Redirect URLs** → add
`https://onair.pmbrull.me/callback/` → **Save URLs**, and remove the pre-ADR-0019 `localhost`
entries. An app created from the README's manifest link already carries it; an app created before
ADR-0019 does not, and that is the error at the top of this page.

The **trailing slash is load-bearing** and Slack compares the string byte for byte, twice — once on
the authorise page and again at the token exchange. `SlackOAuth.redirectURI` is the one place it is
spelled in this repository.

## 4. What "done" looks like

```bash
gh api repos/pmbrull/OnAir/pages --jq '{cname,https_enforced}'
# {"cname":"onair.pmbrull.me","https_enforced":true}

curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://onair.pmbrull.me/callback/
# 200
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://pmbrull.github.io/OnAir/callback/
# 301 https://onair.pmbrull.me/callback/
```

That last redirect is the tell that the claim landed: the project-path URL stops serving and starts
pointing at the custom domain, so a build carrying the old path would break rather than silently
work. Nothing in this repository changes.

Then one live **Connect to Slack**, which is the criterion no check here can fake.

## Lifecycle afterwards

| Event | Action needed |
|---|---|
| New OnAir release | none — the domain is not per version |
| `site/` changes | none — `pages.yml` redeploys; the domain claim survives |
| Certificate expiry | none — GitHub renews it |
| Domain moves or lapses | all three steps again, plus `SlackOAuth.redirectURI`, `site/CNAME` and the README manifest, which A7 will hold together |
