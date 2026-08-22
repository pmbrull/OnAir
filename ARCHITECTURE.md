# Architecture

Structural intent: what depends on what, and the invariants that must not drift. The daily table of
contents is [`CLAUDE.md`](CLAUDE.md); the reasoning behind each choice is in
[`docs/decisions/`](docs/decisions/).

## Shape

```
            ┌────────────────────────────────────────────┐
            │  OnAir (executable)                        │
            │  AppKit · SwiftUI · Security · SMAppService │
            │                                            │
            │  AppDelegate ─▶ AppCoordinator             │
            │  MenuBarView · SettingsView · Doctor       │
            │  TokenStore (the only door to the Keychain)│
            └───┬──────────────┬──────────────┬──────────┘
                │              │              │
         ┌──────▼─────┐  ┌─────▼──────┐  ┌────▼──────┐
         │ DeviceKit  │  │  SlackKit  │─▶│ StatusKit │
         │            │  │            │  │           │
         │ is it      │  │ web API +  │  │ the       │
         │ running?   │  │ OAuth loop │  │ policy    │
         └────────────┘  └────────────┘  └───────────┘
          CoreMediaIO      Network         Foundation
          CoreAudio        Security         only
```

`SlackKit` depends on `StatusKit` because `UserStatus` and `LiveStatus` are the domain types both
sides speak — the pair OnAir writes, and that pair plus the expiry Slack actually holds (ADR-0015).
`DeviceKit` and `StatusKit` depend on nothing but Foundation and the C frameworks. Nothing depends
on the app.

## Targets

| Target | Kind | Owns | May import |
|---|---|---|---|
| `DeviceKit` | library | Whether any camera or microphone is running somewhere; the device inventory `doctor` prints; hot-plug re-attachment | Foundation, CoreMediaIO, CoreAudio |
| `StatusKit` | library | `UserStatus`, `LiveStatus`, `StatusPolicy`, `StatusEngine`, `EmojiShortcode` — the debounce, the pause, the override verdict, the ownership test, the restore rule and the shortcode table. **Depends on nothing** | Foundation |
| `SlackKit` | library | `SlackClient` (six calls: profile read/write, identity, three DND), `SlackWire` (decoding), `SlackCredential` and `TokenRefresh.plan` — when a credential is renewed (ADR-0020) — and the OAuth flow: `SlackOAuth`, `PKCE`, `LoopbackReceiver` | Foundation, Network, Security, CryptoKit, StatusKit |
| `OnAir` | executable | Menu bar, Settings, `TokenStore`, `PolicyStore`, `LaunchAtLogin`, `AppCoordinator`, `Doctor` | everything above + AppKit, SwiftUI, ServiceManagement |
| `site/` | static pages, not a Swift target | The relay page Slack redirects to (`callback/index.html`), its landing page, and the `CNAME` that names the host. No build step and no dependencies, so what is served is what is in the repository; deployed by `.github/workflows/pages.yml` (ADR-0019) | nothing — plain HTML, CSS, JavaScript |

Two files in the tree are generated, committed, and never fetched at build or run time (ADR-0004):
`Sources/StatusKit/EmojiTable.swift`, 1913 shortcode → glyph pairs vendored from a pinned tag of
github/gemoji by `scripts/generate-emoji-table.sh` (ADR-0014); and `Resources/AppIcon.icns`, drawn
by `scripts/make-icon.swift` via `make icon`. Regenerate them; do not edit them.

## Invariants

**A1 — Dependency direction is one-way.** App → kits. `SlackKit → StatusKit` is the only permitted
sibling edge; every other pair is checked and rejected. No kit imports the app.

**A2 — Kits are headless.** No kit imports AppKit, SwiftUI, Cocoa, UIKit or ServiceManagement. The
invariant a well-meaning change breaks: opening the browser during OAuth *feels* like part of the
OAuth flow, which is why `SlackOAuthSession` hands back a URL and the app calls `NSWorkspace`
(ADR-0002). "Headless" is not "never rendered" — it is about the framework, not the intent.

**A3 — Everything that decides lives in `StatusKit`.** The app performs; it does not choose. The
debounce (`StatusEngine.advance`), the override rule (`StatusPolicy.verdict(forLive:)`), the
ownership test (`StatusEngine.stillOwns`) and the restore rule (`LiveStatus.restoration(now:)`,
which decides whether a stashed status goes back or gets cleared) are pure functions in the target
with no dependencies, because the app target has no tests and logic that lives there is logic
nothing can assert on. Wording follows the same line the moment it changes what a control *means*:
`StatusPolicy.isRunning` is `!paused` as a tested property, not a `Binding` inversion in a view. A
new `if` in `AppCoordinator` that changes *whether* something happens belongs on the other side of
this line. This one is a reviewer rule — no grep can decide it.

**A4 — The Slack token lives in the Keychain and nowhere else.** Not `UserDefaults`, not a file,
not a log line, not an error string, not an interpolated string. `TokenStore` is the only file
permitted to call `SecItem*`; a kit never stores a credential. The one place a token may be
interpolated is the `Authorization: Bearer` header in `SlackClient`, and that line is named
explicitly in the check rather than the rule being softened (ADR-0006).

**A5 — OnAir never opens a camera or microphone stream.** It reads `IsRunningSomewhere` and nothing
else. `AVCaptureSession`, `AVCaptureDevice`, `CMSampleBuffer`, `AudioDeviceStart`, `AVAudioEngine`
and `CMIODeviceStartStream` are build failures anywhere in `Sources/`, and an
`NSCameraUsageDescription` key in `Resources/` is a build failure too. CI re-checks the assembled
bundle's plist, because this property has to hold in the shipped artefact and not only in the
sources. It is the whole reason OnAir needs no permission (ADR-0001).

**A6 — OnAir imports no PKCS#12 archive.** `SecPKCS12Import` anywhere in `Sources/` is a build
failure. It used to be the weaker "must pass `kSecImportToMemoryOnly`", because OnAir minted a
`localhost` certificate for its OAuth listener; without that option macOS imports the certificate
*and its private key* into the login keychain on every distinct archive, and each deposited key's
ACL names the binary that imported it — so a rebuilt OnAir makes macOS ask the user for their login
password. Measured before the fix: 268 stranded keys on one machine, most of them minted by
`make verify` itself. Since ADR-0019 there is no certificate at all, so the check guards a
*reintroduction*: a future TLS listener would bring the whole failure back with it (ADR-0016,
ADR-0019).

**A7 — The relay page and the listener agree.** Slack's Redirect URL is a page in `site/`, served
at the domain the repository's GitHub Pages setting claims (ADR-0019). `site/CNAME` *declares* that
domain and A7 uses it as the source of truth for the string — but on a workflow-built site GitHub
ignores the file, so it does not claim anything
([`docs/runbooks/callback-domain.md`](docs/runbooks/callback-domain.md) §2). The port it hands the callback back to must be
`SlackOAuth.defaultPort`, the path must be `LoopbackReceiver.callbackPath`, and
`SlackOAuth.redirectURI` must name that domain. Every one of those values lives in exactly two
files, and a mismatch fails a login with an error that names neither OnAir nor the reason — a
browser error page on a port nothing is listening on. The page ships from this repository so the
two *can* be checked together; A7 is what does the checking.

A1, A2, A4, A5, A6 and A7 are decided by `./scripts/check-architecture.sh`, which runs in
`make verify`, in the pre-commit hooks, in CI, and in the Pages deploy. A3 is decided by
`architecture-reviewer`.

## Data flow, one meeting

1. `CameraMonitor` and `MicrophoneMonitor` hold property listeners on every device, plus one on the
   device *list* so a webcam plugged in mid-call is seen. Each coalesces: CoreMediaIO fires once per
   device, and one camera starting produces several notifications that mean the same thing.
2. `DeviceWatcher` joins them into a `DeviceSnapshot` and drops any snapshot equal to the last.
3. `AppCoordinator.pump()` calls `StatusEngine.advance(cameraInUse:microphoneInUse:policy:now:)`,
   which applies the debounce and returns an intent plus a `wakeAt` to schedule. Pumps coalesce
   rather than drop: a device change arriving during a Slack call is looked at *after* it, or the
   camera could go off mid-apply and nothing would ever put the status back.
4. On `.apply`, the coordinator asks `engine.appliedPrevious` whether this is a **fresh** apply or a
   **refresh**. Fresh: read the live status as a `LiveStatus` — the pair *and* Slack's
   `status_expiration` — run `policy.verdict(forLive:)` on `effectiveStatus(now:)`, and either skip
   or stash-and-write. What gets stashed is the whole `LiveStatus`, expiry included (ADR-0015).
   Refresh: write without re-reading, because the live status is OnAir's own and stashing it would
   strand the status forever (ADR-0008).
5. On `.restore`, the coordinator reads the live status and calls `engine.stillOwns(_:)`, which
   compares the expiry too: OnAir always writes `0`, so an expiry that has appeared under the same
   words is evidence somebody else wrote them. If the user edited it by hand during the call, OnAir
   stands down and says so. Otherwise `LiveStatus.restoration(now:)` decides *what* to write — the
   stashed status with the expiry it arrived with, or a clear if that expiry fell due during the
   call, because Slack would have cleared it anyway (ADR-0015). `AppCoordinator.putBack` performs
   the answer and names which branch it took in the menu.
6. Failures classify themselves: `requiresReconnect` turns the menu bar red and stops retrying,
   `rateLimited` schedules a wake at Slack's own `Retry-After`, anything else retries with a
   doubling backoff from 15s to 5 minutes. The engine's state is deliberately *not* advanced on
   failure, so the next `advance` returns the same intent.
7. On quit, `applicationShouldTerminate` returns `.terminateLater` and puts the status back
   through the same `putBack`, expiry and all (ADR-0009, amended by ADR-0015).

## Where a new signal goes

One type conforming to `ActivityMonitor` in `Sources/DeviceKit/`, one field on `DeviceSnapshot`, one
`watchX` flag on `StatusPolicy`, one clause in `StatusEngine.advance`. The obligation that comes
with the seam: **run `make doctor` on real hardware before choosing the default.** ADR-0011 exists
because the microphone default was going to be wrong and only a real machine said so.

## Where a new Slack call goes

One method on `SlackClient`, one decoder in `SlackWire`, one scope in `SlackOAuth.userScopes` — and
a new scope means every existing user has to reconnect, so it is a decision rather than a detail.
The decoder is testable without a network by construction, which is the point of the split.
