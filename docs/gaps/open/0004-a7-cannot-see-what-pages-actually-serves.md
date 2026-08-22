---
id: GAP-0004
title: A7 compares two files in this repository and cannot see what Pages actually serves
status: open
impact: the gate stayed green through an outage that made connecting impossible
opened: 2026-08-22
closed_by:
---

**Question.** What would have caught the callback domain being unreachable, before a human tried to
connect?

**Why it's open.** A7 (`scripts/check-architecture.sh`) asserts that `site/CNAME` and
`SlackOAuth.redirectURI` name the same host, and that the relay page hands back to
`SlackOAuth.defaultPort` and `LoopbackReceiver.callbackPath`. Every one of those is a comparison
between two files *in this repository*. None of them can reach the two facts the redirect URL
actually depends on:

- whether `onair.pmbrull.me` resolves at all, and
- whether the repository's GitHub Pages setting claims it — which `site/CNAME` does **not** do on a
  workflow-built site (`docs/runbooks/callback-domain.md` §2).

Measured 2026-08-22: both were false for the whole period between ADR-0019 merging and the first
connect attempt, and `make verify` was green throughout. The invariant held; the property it stands
for did not.

The same blindness covers the copies of the redirect URL that A7 does not read — the README
manifest and its percent-encoded links, the two runbooks, `docs/dev-loop.md`, `CLAUDE.md`,
`pages.yml`, `LoopbackReceiver.swift` and `SlackOAuthTests.swift`. A domain move updates
`SlackOAuth.redirectURI` and `site/CNAME`, passes A7, and leaves a manifest link pointing at a host
nobody owns — which is `redirect_uri did not match any configured URIs` again, from the other side.

**Blocks.** The claim that A7 keeps the callback contract whole. It keeps two thirds of it whole
mechanically and the rest by hand.

**What would answer it.** Something that fetches. A live `curl` of `https://<site/CNAME>/callback/`
asserting `200` would have caught the outage, but it makes the gate depend on the network, which no
other check here does — and the release lane (ADR-0018) is where an offline gate matters most. The
narrower alternative is a grep that holds the by-hand copies to the same host, which catches the
domain-move case without a network call and does nothing for reachability. Both are cheap; neither
has been decided.

**Adjacent.** [GAP-0002](0002-pkce-flow-unverified-against-a-live-workspace.md) is the same shape
one layer up — a live Connect is the only thing that proves the whole path, and no check in this
repository can fake it.
