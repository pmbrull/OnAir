---
id: GAP-0001
title: The Slack response fixtures are documentation-derived, never captured
status: open
impact: SlackKit's parser tests prove it matches our belief about Slack, not Slack
opened: 2026-08-12
closed_by:
---

**Question.** Do `users.profile.get`, `users.profile.set`, `auth.test` and `oauth.v2.access`
actually return the shapes in `Tests/SlackKitTests/SlackResponseFixtures.swift`?

**Why it's open.** They were written from Slack's documentation, because no workspace and no token
were available when the parser was built. `.claude/rules/real-data-tests.md` is unambiguous about
what that is worth: a hand-written fixture encodes our belief and then confirms it. It proves the
parser matches the fixture, which is the one thing never in doubt.

The specific things a real capture could falsify:

- whether `status_emoji` and `status_text` are always both present on a profile with no status, or
  whether one can be absent (`SlackWire.status` throws on absence, and that choice is load-bearing
  for ADR-0008 — if Slack really does omit them, Connect breaks for everyone)
- whether a user-scope-only install really returns no top-level `access_token`
- the exact `error` codes for an expired versus a revoked token, which decide whether OnAir tells
  the user to reconnect or retries quietly
- whether `Retry-After` is present on every 429

**Blocks.** Nothing from shipping — the flow is exercised end to end by `LoopbackTests`, and the
one live path is covered by `make doctor-slack`. It blocks the claim that `SlackKit` is verified.

**Provisional handling.** The fixtures are marked as documentation-derived in a header comment on
the file itself, with the capture commands inline, so nobody later mistakes them for evidence.
`SlackResponseFixtures.profileMissingStatusKeys` exists specifically to pin the behaviour that
worries us most.

Close this by capturing real output the first time a token exists:

```sh
curl -s -H "Authorization: Bearer $SLACK_USER_TOKEN" https://slack.com/api/auth.test
curl -s -H "Authorization: Bearer $SLACK_USER_TOKEN" https://slack.com/api/users.profile.get
```

and pasting it in verbatim. **Never edit a fixture to match the code** — capture fresh output, or
the signal becomes a permanent blind spot.
