# Runbook — first run

Getting from a fresh clone to a status that changes itself. Fifteen minutes, most of it in Slack's
web UI.

## 1. Build and install

```bash
make install
open /Applications/OnAir.app
```

A `video` glyph appears in the menu bar. There is no Dock icon and no window — that is `LSUIElement`
and it is intentional.

## 2. Create the Slack app

OnAir ships **no** client secret (ADR-0005), so the Slack app is yours.

1. <https://api.slack.com/apps> → **Create New App** → **From scratch**. Name it anything; pick your
   workspace.
2. **OAuth & Permissions** → scroll to **User Token Scopes** — *not* Bot Token Scopes, which cannot
   change your status — and add:
   - `users.profile:read`
   - `users.profile:write`
3. Same page, **Redirect URLs** → **Add New Redirect URL**:
   ```
   https://localhost:51234/callback
   ```
   → **Add** → **Save URLs**. It must match to the character, including the port. Settings › Slack
   has a Copy button for exactly this.

   Slack will reject an `http://` URL here. That is not a mistake on your part — it is the
   constraint the whole loopback design is built around.
4. **Basic Information** → **App Credentials**: copy the **Client ID** and **Client Secret**.

## 3. Connect

Settings › Slack (⌘, from the menu panel):

1. Paste the client id and secret → **Save**. Both go straight to the Keychain (ADR-0006).
2. **Connect to Slack**. Your browser opens Slack's authorise page.
3. Approve. The browser then warns **"Your connection is not private"** / **"This Connection Is Not
   Private"**.

   **This is expected.** OnAir is serving the callback from `https://localhost:51234` with a
   certificate it minted for itself, because Slack refuses to register a plain-HTTP redirect. The
   alternative was routing your authorisation code through somebody else's web server, which is
   worse. Click **Advanced → Proceed to localhost**, or **Show Details → visit this website**.

   You should see **"OnAir is connected"**. Close the tab.
4. The menu panel now shows your name and workspace.

## 4. Check it against your own machine

```bash
make doctor
```

Look at the microphone rows. If any reads `in use` while you are not in a call, leave
**Watch the microphone** off — something holds it open permanently and turning it on would pin your
status (ADR-0011).

## 5. Try it

Open Photo Booth. Within a few seconds the menu-bar glyph fills in and your Slack status changes.
Close it; after a minute the old status comes back.

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Port 51234 is already in use" | Something else holds the port. `lsof -iTCP:51234 -sTCP:LISTEN`. |
| "Slack refused the call: invalid_scope" / no status changes | Scopes were added under **Bot** Token Scopes instead of **User** Token Scopes. Fix, reinstall the app to the workspace, reconnect. |
| Browser says "redirect_uri did not match" | The Redirect URL is not saved, or differs by a character. |
| Connected, camera on, nothing happens | The menu's last line says why. Most often: you already had a status set and **Replace a status I set myself** is off (ADR-0008). |
| Launch at login does nothing | `SMAppService` needs a signed bundle. `make app` says whether it signed or fell back to ad-hoc. |
| Status stuck on after a crash | Known and accepted — there is no server-side expiry (ADR-0009). Clear it in Slack. |
