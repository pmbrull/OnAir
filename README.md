# OnAir

A macOS menu-bar app that sets your Slack status when your camera turns on, and puts the old one
back when it turns off.

**It never opens your camera.** It asks macOS whether one is running — the same question the green
dot answers — and never reads a frame or a sample. So it needs no camera permission, no microphone
permission, and never appears in Privacy & Security. That property is enforced by a check that
fails the build, not by a promise: see [invariant A5](ARCHITECTURE.md#invariants).

```
┌──────────────────────────────┐
│ ● pere · Collate             │
│   🎥 On camera               │
├──────────────────────────────┤
│ ● Camera              in use │
│ ○ Microphone     not watched │
├──────────────────────────────┤
│ Set your status to On camera.│
│                        14:02 │
├──────────────────────────────┤
│ Pause OnAir            ( ●   │
│ Settings…              Quit  │
└──────────────────────────────┘
```

## Install

```bash
git clone git@github.com:pmbrull/SlackStatus.git && cd SlackStatus
make install && open /Applications/OnAir.app
```

Requires macOS 15+ and a Swift 6 toolchain. No dependencies to fetch — there are none
([ADR-0004](docs/decisions/0004-no-third-party-dependencies.md)).

Then follow [`docs/runbooks/first-run.md`](docs/runbooks/first-run.md): you create a small Slack app
of your own, paste its client id and secret once, and press Connect. OnAir ships no client secret,
because a secret compiled into a distributed binary is not a secret
([ADR-0005](docs/decisions/0005-oauth-over-a-self-signed-https-loopback.md)).

## What it does

- **Watches the camera** via CoreMediaIO, and the microphone too if you turn it on.
- **Debounces both edges, asymmetrically** — 3s before setting, 60s before clearing, so a camera
  blip never reaches your colleagues and back-to-back meetings do not make your status flicker.
- **Leaves a status you set yourself alone**, by default, and says so in the menu. Turn on
  *Replace a status I set myself* if you would rather it took over.
- **Never undoes your own edit.** If you change your status by hand during a call, OnAir notices it
  no longer owns it and stands down.
- **Restores on quit**, including when you quit mid-meeting.
- **Pause**, from the menu, immediate in both directions.
- **Launch at login**, and a **`doctor`** command that shows you exactly what your Mac's devices are
  doing and what the app would decide about it.

## Check it against your own Mac first

```bash
make doctor
```

If any microphone row says `in use` while you are not in a call, leave *Watch the microphone* off:
something on your machine — an audio mixer, a virtual device, a noise-suppression tool — holds it
open permanently, and watching it would pin your status on for good. That is why the microphone is
off by default ([ADR-0011](docs/decisions/0011-watch-the-camera-by-default-the-microphone-on-request.md));
it was found by running `doctor`, not by reasoning about it.

## Where your data goes

- **Your Slack token** is in the macOS Keychain and nowhere else — not in a file, not in
  `UserDefaults`, not in a log line, not in an error message. Enforced by a build check
  ([ADR-0006](docs/decisions/0006-the-token-lives-in-the-keychain.md)).
- **The scopes are `users.profile:read` and `users.profile:write`**, user-scoped. No bot token. It
  cannot read your messages, and it is not able to.
- **The OAuth authorisation code never leaves your machine.** The callback lands on a TLS listener
  bound to loopback, using a certificate OnAir mints locally. Your browser will warn you about it
  once; that warning is the price of not routing your login through somebody else's server.
- **Nothing else is sent anywhere.** No telemetry, no analytics, no crash reporting.

## Known limitations

- **A crash or a force-quit mid-call leaves your status set.** There is no server-side expiry, on
  purpose — an expiring status is its own surprise when it vanishes mid-meeting
  ([ADR-0009](docs/decisions/0009-restore-on-quit-is-the-only-safety-net.md)). Clear it in Slack.
- **One workspace.** Multiple accounts are not built.
- **It cannot tell you which app is using the camera**, only that something is. Finding out would
  need exactly the privileges this app refuses.
- **Screen sharing without a camera does not count.** Nothing detects it yet.
- **Slack's responses are not yet verified against a live workspace** — the parser's fixtures come
  from Slack's documentation, and that is recorded rather than glossed over
  ([GAP-0001](docs/gaps/open/0001-slack-fixtures-are-documented-not-captured.md)).

## Development

```bash
make verify   # references + architecture invariants + format + lint + build + test
make test     # 68 tests in 8 suites — use this, not `swift test`
```

`swift test` will not work on a machine with only the Command Line Tools: XCTest ships with Xcode,
so the suite is written against Swift Testing and `make test` supplies the search paths CLT does
not. [`docs/dev-loop.md`](docs/dev-loop.md) has the details.

The repo carries its own working agreement — [`CLAUDE.md`](CLAUDE.md),
[`ARCHITECTURE.md`](ARCHITECTURE.md), [`docs/`](docs/) and [`.claude/`](.claude/) — with eleven ADRs
recording every load-bearing choice and the alternative it beat.

## TODO

- [ ] Run the connect flow against a live workspace and capture real Slack responses (GAP-0001).
- [ ] Decide whether screen sharing is worth a third signal.
- [ ] Multiple workspaces, if a second one ever gets daily use.
- [ ] Revisit the crash net if a stranded status actually happens (ADR-0009).
