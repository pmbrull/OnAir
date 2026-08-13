# Runbook — first run

Getting from a fresh clone to a status that changes itself.

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
workspace blocks it and you are bringing your own. Create one (five minutes, once):

1. <https://api.slack.com/apps> → **Create New App** → **From scratch**, in your workspace.
2. **OAuth & Permissions** → **User Token Scopes** — *not* Bot Token Scopes, which cannot change
   your status — add `users.profile:read` and `users.profile:write`.
3. Same page, **Redirect URLs** → add exactly (Settings has a Copy button):
   ```
   https://localhost:51234/callback
   ```
   → **Save URLs**. Slack rejects `http://` here; that is the constraint, not a typo.
4. **OAuth & Permissions** → enable **PKCE**. This marks the app a public client — one-way, and
   exactly what OnAir needs; no secret is ever used (Slack's "Using PKCE" doc has the details).
5. **Basic Information** → **App Credentials** → copy the **Client ID** — only the id — into
   Settings, press Save, then Connect as above.

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

Open Photo Booth. Within a few seconds the menu-bar glyph fills in and your Slack status changes.
Close it; after a minute the old status comes back.

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Port 51234 is already in use" | Something else holds the port. `lsof -iTCP:51234 -sTCP:LISTEN`. |
| Exchange fails with a Slack error right after authorising | If using your own app: PKCE not enabled (step 2b.4), or scopes under **Bot** instead of **User** Token Scopes. See also GAP-0002. |
| Browser says "redirect_uri did not match" | The Redirect URL is not saved, or differs by a character. |
| Connected, camera on, nothing happens | The menu's last line says why. Most often: you already had a status set and **Replace a status I set myself** is off (ADR-0008). |
| Launch at login does nothing | `SMAppService` needs a signed bundle. `make app` says whether it signed or fell back to ad-hoc. |
| Status stuck on after a crash | Known and accepted — no server-side expiry (ADR-0009). Clear it in Slack. |
