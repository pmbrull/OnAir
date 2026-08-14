# Runbook — first run

Getting from a fresh clone to a status that changes itself. This is the **user** runbook; the
maintainer's one-time counterpart is [`shared-app.md`](shared-app.md).

Who does what, and how often:

| Role | Slack console work | How often |
|---|---|---|
| Maintainer | create the shared app from the manifest, activate distribution | **once, ever** ([`shared-app.md`](shared-app.md)) |
| User (shared app baked in) | none — press Connect, approve in the browser | authorise once per workspace |
| User bringing their own app (§2b) | create one app from the manifest | once, then as above |

"Approve in the browser" is Slack's consent page, not app creation — and it is also what installs
the app to your workspace. **Never press "Install to Workspace" in Slack's dashboard** for this
app; that flow sends no user scopes and fails with "No scopes requested" (see
[`shared-app.md`](shared-app.md) §2).

## 1. Build and install

```bash
make install
open /Applications/OnAir.app
```

A `video` glyph appears in the menu bar. No Dock icon, no window — that is `LSUIElement` and it is
intentional.

## 2. Connect

Settings › Slack (⌘, from the menu panel) → **Connect to Slack**.

Your browser opens Slack's authorise page. Approve it. The browser then warns **"Your connection is
not private"** — that is OnAir's own certificate for `localhost`, which exists because Slack
refuses plain-HTTP redirect URLs (ADR-0005). Click **Advanced → Proceed to localhost** once. You
should land on **"OnAir is connected"**; the menu panel now shows your name and workspace.

There is nothing to paste and no secret anywhere: OnAir is a public client and proves each
connection with PKCE (ADR-0012).

## 2b. Only if Settings shows a "Client ID" field

That means this build ships no Slack app id — either the shared app is not registered yet, or your
workspace blocks it and you are bringing your own. The app manifest in the README does all of the
configuration in one paste; [this link](
https://api.slack.com/apps?new_app=1&manifest_json=%7B%22display_information%22%3A%7B%22name%22%3A%22OnAir%22%2C%22description%22%3A%22Sets%20your%20Slack%20status%20when%20your%20camera%20turns%20on.%22%2C%22background_color%22%3A%22%23a01d21%22%7D%2C%22oauth_config%22%3A%7B%22redirect_urls%22%3A%5B%22https%3A%2F%2Flocalhost%3A51234%2Fcallback%22%5D%2C%22scopes%22%3A%7B%22user%22%3A%5B%22users.profile%3Aread%22%2C%22users.profile%3Awrite%22%2C%22dnd%3Aread%22%2C%22dnd%3Awrite%22%5D%7D%2C%22pkce_enabled%22%3Atrue%7D%2C%22settings%22%3A%7B%22org_deploy_enabled%22%3Afalse%2C%22socket_mode_enabled%22%3Afalse%2C%22token_rotation_enabled%22%3Afalse%7D%7D)
opens Slack's **Create an app** flow with it pre-filled.

Manual equivalent: <https://api.slack.com/apps> → **Create New App** → **From a manifest** → pick
your workspace → paste the manifest from the README → **Create**.

What the manifest sets, so you can audit rather than trust it: the four user scopes
(`users.profile:read/write` for the status, `dnd:read/write` for pausing notifications), the
redirect URL
(`https://localhost:51234/callback` — Slack rejects `http://`, which is why it is https), PKCE on
(public client, one-way — no secret is ever used), and **token rotation off** — rotation would
expire every token in hours, and OnAir has no refresh loop (GAP-0002).

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

adds one read-only Slack round trip: who you are, which workspace, your current status. This run is
also what closes GAP-0002 — note which endpoint answered the exchange and whether the response
carried an `expires_in`.

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
| Browser says "redirect_uri did not match" | The Redirect URL is not saved, or differs by a character. |
| Connected, camera on, nothing happens | The menu's last line says why. Most often: you already had a status set and **Replace a status I set myself** is off (ADR-0008). |
| Launch at login does nothing | `SMAppService` needs a signed bundle. `make app` says whether it signed or fell back to ad-hoc. |
| Status stuck on after a crash | Known and accepted — OnAir gives its own status no server-side expiry (ADR-0009). Clear it in Slack. |
| Your old status was cleared instead of restored | Its `status_expiration` fell due during the call. Slack would have cleared it anyway, so OnAir does not revive a status you had already stopped having (ADR-0015). The menu's last line names it. |
