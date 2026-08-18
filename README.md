# OnAir

A macOS menu-bar app that sets your Slack status when your camera turns on, and puts the old one
back when it turns off.

**It never opens your camera.** It asks macOS whether one is running — the same question the green
dot answers — and never reads a frame or a sample. So it needs no camera permission, no microphone
permission, and never appears in Privacy & Security. That property is enforced by a check that
fails the build, not by a promise: see [invariant A5](ARCHITECTURE.md#invariants).

```
┌───────────────────────────────────┐
│ ● pere · Collate                  │
│   🎥 On camera                    │
├───────────────────────────────────┤
│ ● Camera                   in use │
│ ○ Microphone          not watched │
├───────────────────────────────────┤
│ Set your status to 🎥 On camera.  │
│                             14:02 │
├───────────────────────────────────┤
│ OnAir is running            (  ●) │
│ Settings…                    Quit │
└───────────────────────────────────┘
```

## Install

```bash
brew install --cask pmbrull/tap/onair
```

Signed, notarized, universal (Apple Silicon + Intel), macOS 15+. Or build from source — requires
a Swift 6 toolchain, and no dependencies to fetch because there are none
([ADR-0004](docs/decisions/0004-no-third-party-dependencies.md)):

```bash
git clone git@github.com:pmbrull/OnAir.git && cd OnAir
make install && open /Applications/OnAir.app
```

Then press **Connect to Slack** in Settings and approve in the browser — that is the whole setup.
OnAir is a public client ([ADR-0012](docs/decisions/0012-a-public-client-pkce-and-no-secret-anywhere.md)):
it ships only a Slack app *id* and proves each connection with PKCE, so **no secret exists in the
binary, in your Keychain, or anywhere else**.

### If Settings shows a "Client ID" field

That build ships no Slack app id, so you bring your own — one minute with the manifest below.
[**Click here to create it pre-filled**](https://api.slack.com/apps?new_app=1&manifest_json=%7B%22display_information%22%3A%7B%22name%22%3A%22OnAir%22%2C%22description%22%3A%22Sets%20your%20Slack%20status%20when%20your%20camera%20turns%20on.%22%2C%22background_color%22%3A%22%23a01d21%22%7D%2C%22oauth_config%22%3A%7B%22redirect_urls%22%3A%5B%22https%3A%2F%2Fonair.pmbrull.me%2Fcallback%2F%22%5D%2C%22scopes%22%3A%7B%22user%22%3A%5B%22users.profile%3Aread%22%2C%22users.profile%3Awrite%22%2C%22dnd%3Aread%22%2C%22dnd%3Awrite%22%5D%7D%2C%22pkce_enabled%22%3Atrue%7D%2C%22settings%22%3A%7B%22org_deploy_enabled%22%3Afalse%2C%22socket_mode_enabled%22%3Afalse%2C%22token_rotation_enabled%22%3Afalse%7D%7D), or go to
[api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**, pick
your workspace, and paste:

```json
{
    "display_information": {
        "name": "OnAir",
        "description": "Sets your Slack status when your camera turns on.",
        "background_color": "#a01d21"
    },
    "oauth_config": {
        "redirect_urls": [
            "https://onair.pmbrull.me/callback/"
        ],
        "scopes": {
            "user": [
                "users.profile:read",
                "users.profile:write",
                "dnd:read",
                "dnd:write"
            ]
        },
        "pkce_enabled": true
    },
    "settings": {
        "org_deploy_enabled": false,
        "socket_mode_enabled": false,
        "token_rotation_enabled": false
    }
}
```

The manifest sets the scopes, the redirect URL, and enables PKCE (which marks the app a public
client — one-way, and exactly what OnAir needs). It also keeps token rotation **off**, which is
still the setting to prefer: with rotation on, every token expires after twelve hours. OnAir
renews them for you when that happens (ADR-0020), so you authorise once either way — but a
rotating credential dies for good if the app goes unused for thirty days, and a non-rotating one
does not. Note that Slack does not let you turn rotation back off once it is on. After **Create**:
**Basic Information → App Credentials** → copy the **Client ID** — only the id — into Settings,
Save, Connect.

**Do not press "Install to Workspace" in Slack's dashboard** — that flow cannot drive a PKCE
user-scope app and fails with "No scopes requested". Pressing **Connect** in OnAir *is* the
install.

### Who does what, and how often

| | Slack console | How often |
|---|---|---|
| **You (user)** | nothing — Connect and approve in the browser | authorise once per workspace |
| **Maintainer** | create the shared app, activate distribution ([runbook](docs/runbooks/shared-app.md)) | once, ever |
| **Bring-your-own-app** (workspace blocks the shared one) | create one app from the manifest above | once |

## What it does

- **Watches the camera** via CoreMediaIO, and the microphone too if you turn it on.
- **Debounces both edges, asymmetrically** — 3s before setting, 60s before clearing, so a camera
  blip never reaches your colleagues and back-to-back meetings do not make your status flicker.
- **Leaves a status you set yourself alone**, by default, and says so in the menu. Turn on
  *Replace a status I set myself* if you would rather it took over.
- **Never undoes your own edit.** If you change your status by hand during a call, OnAir notices it
  no longer owns it and stands down.
- **Pauses your notifications too, if you opt in** — Do Not Disturb in self-renewing half-hour
  slices while on camera, resumed afterwards. A snooze you set yourself is never touched, and if
  OnAir dies mid-call the slice lapses on its own (ADR-0013).
- **Restores on quit**, including when you quit mid-meeting.
- **Puts back the clock as well as the words.** A status written by Google Calendar or a similar
  integration expires by itself — that is how it gets cleared, and nothing comes back to do it a
  second time. OnAir restores that expiry along with the status, and if it fell due while you were
  on camera it clears your status instead of reviving it (ADR-0015).
- **One switch**, *OnAir is running*, in the menu — off takes effect immediately, and so does on.
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
- **The scopes are `users.profile:read/write` and `dnd:read/write`**, user-scoped. No bot token.
  It can change your status and snooze your notifications; it cannot read your messages, and it is
  not able to.
- **The OAuth authorisation code passes through one page, and is useless to it.** Slack redirects
  your browser to `https://onair.pmbrull.me/callback/` — a static page in this repository
  ([`site/`](site/), served by GitHub Pages) — which hands the code straight to a listener on
  `127.0.0.1` and does nothing else. It stores nothing, runs no server-side code, loads no
  third-party script, and could not use the code if it kept it: PKCE binds the code to a verifier
  generated on your Mac and never sent anywhere but Slack
  ([ADR-0019](docs/decisions/0019-the-callback-lands-on-a-page-we-host.md)).
  The token itself is never on that page's side of the wire — it is a direct POST from your Mac to
  Slack. Before this, the callback landed on a TLS listener using a certificate OnAir minted
  locally, and your browser warned you about it every single time.
- **Nothing else is sent anywhere.** No telemetry, no analytics, no crash reporting.

## Known limitations

- **A crash or a force-quit mid-call leaves your status set.** OnAir never gives its own status a
  server-side expiry, on purpose — an expiring status is its own surprise when it vanishes
  mid-meeting ([ADR-0009](docs/decisions/0009-restore-on-quit-is-the-only-safety-net.md)). The only
  expiry it ever writes is one it read off your previous status and put back
  ([ADR-0015](docs/decisions/0015-carry-the-previous-status-expiry.md)). Clear it in Slack.
- **One workspace.** Multiple accounts are not built.
- **It cannot tell you which app is using the camera**, only that something is. Finding out would
  need exactly the privileges this app refuses.
- **Screen sharing without a camera does not count.** Nothing detects it yet.
- **Workspace custom emoji show as `:their_name:`, not a picture.** OnAir renders the standard set
  from a vendored table; a custom emoji is data held inside one workspace, and resolving it would
  cost a new Slack scope and a reconnect for every user
  ([ADR-0014](docs/decisions/0014-render-shortcodes-from-a-vendored-table.md)). Slack itself still
  shows it correctly — it is only OnAir's own menu that cannot.
- **Slack's responses are not yet verified against a live workspace** — the parser's fixtures come
  from Slack's documentation ([GAP-0001](docs/gaps/open/0001-slack-fixtures-are-documented-not-captured.md)),
  and the PKCE exchange plus token longevity are documented-but-unmeasured
  ([GAP-0002](docs/gaps/open/0002-pkce-flow-unverified-against-a-live-workspace.md)). Recorded
  rather than glossed over.

## Development

```bash
make verify   # references + architecture invariants + format + lint + build + test
make test     # 115 tests in 13 suites — use this, not `swift test`
```

`swift test` will not work on a machine with only the Command Line Tools: XCTest ships with Xcode,
so the suite is written against Swift Testing and `make test` supplies the search paths CLT does
not. [`docs/dev-loop.md`](docs/dev-loop.md) has the details.

The repo carries its own working agreement — [`CLAUDE.md`](CLAUDE.md),
[`ARCHITECTURE.md`](ARCHITECTURE.md), [`docs/`](docs/) and [`.claude/`](.claude/) — with eighteen ADRs
recording every load-bearing choice and the alternative it beat.

## TODO

- [x] Register the shared OnAir Slack app (PKCE on) and fill `SlackOAuth.builtInClientID` (ADR-0012).
- [x] Run the connect flow against a live workspace — `oauth.v2.access` accepted the PKCE exchange,
      and `make doctor-slack` came back with a real profile (GAP-0002).
- [x] Cut v0.1.0 — notarized by Apple first try, stapled, and installing from the tap
      ([runbook](docs/runbooks/release.md), ADR-0017). The brew line above is now the reality.
- [x] Move the release lane into CI — a push to `main` derives the version, notarizes, publishes and
      bumps the cask (ADR-0018). **v0.2.0 shipped through Actions**, notarized first try, and
      `brew upgrade` moved an installed app to it ([runbook](docs/runbooks/release.md)).
- [ ] Let a real merge choose the version — every release so far passed `workflow_dispatch` an
      explicit one, so the bump rule has never picked a shipped version by itself.
- [ ] Protect `main`. Since ADR-0018 a push there signs and notarizes code, which makes
      review-before-merge a code-signing control.
- [x] Pick a LICENSE — MIT, chosen for the warranty and liability disclaimer.
- [ ] Capture those responses verbatim into `SlackResponseFixtures`, and settle whether the token
      carries an expiry (GAP-0001, GAP-0002).
- [ ] Decide whether screen sharing is worth a third signal.
- [ ] Multiple workspaces, if a second one ever gets daily use.
- [ ] Revisit the crash net if a stranded status actually happens (ADR-0009).
