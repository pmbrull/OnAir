# Runbook — first run

Getting from an install — brew or a fresh clone — to a status that changes itself. This is the
**user** runbook; the maintainer's counterparts are
[`callback-domain.md`](callback-domain.md) (the DNS record and the Pages setting the redirect URL
depends on — §0–§2 before anything else), [`shared-app.md`](shared-app.md) (the Slack app, once
ever) and [`release.md`](release.md) (each release).

Who does what, and how often:

| Role | Slack console work | How often |
|---|---|---|
| Maintainer | claim the callback domain *first*, then create the shared app from the manifest and activate distribution | **once, ever** ([`callback-domain.md`](callback-domain.md), then [`shared-app.md`](shared-app.md)) |
| User (shared app baked in) | none — press Connect, approve in the browser | authorise once per workspace |
| User bringing their own app (§2b) | create one app from the manifest | once, then as above |

"Approve in the browser" is Slack's consent page, not app creation — and it is also what installs
the app to your workspace. **Never press "Install to Workspace" in Slack's dashboard** for this
app; that flow sends no user scopes and fails with "No scopes requested" (see
[`shared-app.md`](shared-app.md) §2).

## 1. Install

Homebrew — v0.1.0 shipped 2026-08-14 and the cask is live:

```bash
brew install --cask pmbrull/tap/onair
open -a OnAir
```

Or from source, with a Swift 6 toolchain:

```bash
make install
open /Applications/OnAir.app
```

A `video` glyph appears in the menu bar. No Dock icon, no window — that is `LSUIElement` and it is
intentional.

## 2. Connect

Settings › Slack (⌘, from the menu panel) → **Connect to Slack**.

Your browser opens Slack's authorise page. Approve it. Slack sends you to
`https://onair.pmbrull.me/callback/` — a page served from this repository — which hands the
authorisation straight back to OnAir on this Mac. There is nothing to click through: the browser
warning that used to appear here was OnAir's own certificate for `localhost`, and ADR-0019 removed
the certificate along with the reason for it. You should land on **"OnAir is connected"**; the menu
panel now shows your name and workspace.

There is nothing to paste and no secret anywhere: OnAir is a public client and proves each
connection with PKCE (ADR-0012).

## 2b. Only if Settings shows a "Client ID" field

That means this build ships no Slack app id — either the shared app is not registered yet, or your
workspace blocks it and you are bringing your own. The app manifest in the README does all of the
configuration in one paste; [this link](
https://api.slack.com/apps?new_app=1&manifest_json=%7B%22display_information%22%3A%7B%22name%22%3A%22OnAir%22%2C%22description%22%3A%22Sets%20your%20Slack%20status%20when%20your%20camera%20turns%20on.%22%2C%22background_color%22%3A%22%23a01d21%22%7D%2C%22oauth_config%22%3A%7B%22redirect_urls%22%3A%5B%22https%3A%2F%2Fonair.pmbrull.me%2Fcallback%2F%22%5D%2C%22scopes%22%3A%7B%22user%22%3A%5B%22users.profile%3Aread%22%2C%22users.profile%3Awrite%22%2C%22dnd%3Aread%22%2C%22dnd%3Awrite%22%5D%7D%2C%22pkce_enabled%22%3Atrue%7D%2C%22settings%22%3A%7B%22org_deploy_enabled%22%3Afalse%2C%22socket_mode_enabled%22%3Afalse%2C%22token_rotation_enabled%22%3Afalse%7D%7D)
opens Slack's **Create an app** flow with it pre-filled.

Manual equivalent: <https://api.slack.com/apps> → **Create New App** → **From a manifest** → pick
your workspace → paste the manifest from the README → **Create**.

What the manifest sets, so you can audit rather than trust it: the four user scopes
(`users.profile:read/write` for the status, `dnd:read/write` for pausing notifications), the
redirect URL
(`https://onair.pmbrull.me/callback/` — a static page in this repository that hands the callback
back to OnAir on your Mac; Slack rejects `http://`, which is why it cannot simply be the loopback,
ADR-0019), PKCE on
(public client, one-way — no secret is ever used), and it *asks for* **token rotation off**. Treat
that as a request rather than a result: the shared app was created from this same manifest and
rotates anyway (ADR-0020, measured 2026-08-18), which expires every token after twelve hours. OnAir
renews a rotating credential itself, so either way you authorise once; rotation off is still
preferable, because a rotating credential is dead for good after thirty days unused, and Slack will
not let you turn rotation back off once it is on.

Then: **Basic Information** → **App Credentials** → copy the **Client ID** — only the id — into
Settings, press Save, and Connect as above.

## 3. Check it against your own machine

```bash
make doctor
```

Look at the microphone rows. If any reads `in use` while you are not in a call, leave
**Watch the microphone** off — something holds it open permanently and turning it on would pin
your status (ADR-0011).

```bash
make doctor-slack
```

adds one read-only Slack round trip: who you are, which workspace, your current status — and a
`renewal` row saying what OnAir would do about the credential's expiry. Doctor never renews
anything itself; it says so when the app would.

That row is what GAP-0002 now turns on. `scheduled for …` means Slack issued a rotating credential
and OnAir will keep it alive; `not needed — Slack issued no expiry` means this app's tokens do not
rotate; `unknown — stored before OnAir could renew; reconnect to find out` is what an upgrade from
v0.3 shows until you reconnect once, because the stored credential predates the fields the plan
reads. The gap closes when a credential has outlived its own expiry with nobody touching it.

## 4. Try it

Open Photo Booth. Within a few seconds the menu-bar glyph fills in and your Slack status changes —
the menu shows the emoji as a glyph, 🎥, not as `:movie_camera:` (ADR-0014). Close it; after a
minute the old status comes back, with whatever expiry it carried before OnAir touched it. If that
expiry fell due while you were on camera — a Google Calendar "In a meeting" whose event has ended —
your status is **cleared** instead of revived, and the menu's last line says so (ADR-0015).

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Port 51234 is already in use" | Something else holds the port. `lsof -iTCP:51234 -sTCP:LISTEN`. |
| "Invalid permissions requested — No scopes requested" in Slack's dashboard | You pressed the dashboard's Install button, which cannot drive a PKCE user-scope app. Skip it: pressing Connect in OnAir is the install. |
| Exchange fails with a Slack error right after authorising | If using your own app: it was created without the manifest and PKCE is off, or the scopes are under **Bot** instead of **User** Token Scopes. See also GAP-0002. |
| Browser says "redirect_uri did not match" | The Redirect URL is not saved on the Slack app, or differs by a character — the trailing slash counts. Maintainers: [`callback-domain.md`](callback-domain.md). |
| The browser stops on `onair.pmbrull.me` and OnAir never notices | The page could not reach the listener. `make doctor` names the port it expects; `lsof -iTCP:51234 -sTCP:LISTEN` says who holds it. |
| Connected, camera on, nothing happens | The menu's last line says why. Most often: you already had a status set and **Replace a status I set myself** is off (ADR-0008). |
| Launch at login does nothing | `SMAppService` needs a signed bundle. `make app` says whether it signed or fell back to ad-hoc. |
| Status stuck on after a crash | Known and accepted — OnAir gives its own status no server-side expiry (ADR-0009). Clear it in Slack. |
| Your old status was cleared instead of restored | Its `status_expiration` fell due during the call. Slack would have cleared it anyway, so OnAir does not revive a status you had already stopped having (ADR-0015). The menu's last line names it. |
