# Runbook — the shared Slack app (maintainer, once ever)

The developer-side half of ADR-0012. Done **once for the lifetime of the project** — not per
release, not per user, not per machine. When it is done, every user's setup is Install → Connect →
Authorize, and Settings has no fields.

## 1. Create the app from the manifest

[This link](https://api.slack.com/apps?new_app=1&manifest_json=%7B%22display_information%22%3A%7B%22name%22%3A%22OnAir%22%2C%22description%22%3A%22Sets%20your%20Slack%20status%20when%20your%20camera%20turns%20on.%22%2C%22background_color%22%3A%22%23a01d21%22%7D%2C%22oauth_config%22%3A%7B%22redirect_urls%22%3A%5B%22https%3A%2F%2Fonair.pmbrull.me%2Fcallback%2F%22%5D%2C%22scopes%22%3A%7B%22user%22%3A%5B%22users.profile%3Aread%22%2C%22users.profile%3Awrite%22%2C%22dnd%3Aread%22%2C%22dnd%3Awrite%22%5D%7D%2C%22pkce_enabled%22%3Atrue%7D%2C%22settings%22%3A%7B%22org_deploy_enabled%22%3Afalse%2C%22socket_mode_enabled%22%3Afalse%2C%22token_rotation_enabled%22%3Afalse%7D%7D)
opens Slack's **Create an app** flow pre-filled with the manifest from the README. Pick the home
workspace → **Create**.

**Which workspace?** An app has two unrelated relationships to workspaces: a **home** (where its
admin console lives, picked here, once) and its **installs** (wherever someone pressed Authorize —
any workspace, once distribution is on). The standard developer shape, and the one this runbook
assumes: home = **a personal workspace you own**, so the app's config and lifecycle outlive your
membership of any workspace that merely *uses* it. Slack's consent page has a workspace picker —
users (including you) install into whatever workspace they choose there.

Creating the app inside the workspace you use it in also works, needs no distribution step for
that workspace, and is sometimes exempt from its app-approval policy — but it parks the app's
administration under that workspace's roof. That is the §2b bring-your-own-app fallback, not the
main path. Either way, creation does **not** bypass a workspace's admin approval for installs.

The manifest sets the four user scopes (profile + DND), the redirect URL, **PKCE on** and **token rotation off**.
PKCE marks the app a public client — one-way, by design (ADR-0012).

## 2. Do NOT press "Install to Workspace"

Slack's dashboard shows a banner asking you to install the app. **Ignore it.** The dashboard
install flow sends no user scopes and no PKCE challenge, so for this app it fails with:

> Invalid permissions requested — No scopes requested

That is the dashboard's limitation, not a misconfiguration. Installation happens through OnAir's
own Connect flow, which is the only flow this app supports — measured on the first real attempt,
2026-08-13.

## 3. Activate public distribution

Without this, only the home workspace can authorise the app — every other workspace's Connect
fails with `invalid_team_for_non_distributed_app`.

App dashboard → **Manage Distribution** → complete the checklist → **Activate Public
Distribution**. Unlisted distribution is exactly this and needs no Slack Marketplace review;
listing in the Marketplace is a separate, optional step this project does not take.

## 4. Bake the id into the build

**Basic Information → App Credentials** → copy the **Client ID** (the id is public; there is
nothing else to copy — the client secret shown on that page is never used by anything, ADR-0012)
into:

```
Sources/SlackKit/OAuth/SlackOAuth.swift → builtInClientID
```

Then `make verify`, and check Settings › Slack shows **no** Client ID field any more.

## 5. Close the loop against the live workspace (GAP-0002)

1. Connect from OnAir; approve. The browser passes through `onair.pmbrull.me` and comes straight
   back — no certificate warning since ADR-0019. If it stops there, the relay could not reach the
   listener: check `make doctor` names the port it is expecting.
2. `make doctor-slack` — identity, current status and its expiry come back, read-only. The
   `expires` row is the field ADR-0015 turns on.
3. Note which endpoint answered the exchange and whether the response carried `expires_in`;
   capture the verbatim `oauth.v2.access` response into `SlackResponseFixtures` (redact the token)
   — that is what closes GAP-0002 and shrinks GAP-0001.

## Lifecycle afterwards

| Event | Action needed |
|---|---|
| New OnAir release | none — the app registration does not change per version |
| New user, any workspace | none here — they press Connect (admin-approval workspaces may gate it) |
| Redirect URL or scopes change | edit the app's manifest in the dashboard (App Manifest page — paste the README's current one); a scope change forces every user to reconnect. Done once already: ADR-0013 added the `dnd` scopes |
| App deleted by accident | recreate from the manifest (steps 1–4); every user reconnects; the id changes |
