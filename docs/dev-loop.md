# Dev loop

How to build, run and exercise OnAir, and what a healthy result looks like.

## Commands

```bash
make verify        # the gate: references + arch + fmt-check + lint + build + test
make doctor        # everything the app does, minus the window — against this Mac's real hardware
make doctor-slack  # as doctor, plus one read-only Slack round trip
make test          # the suite
make app           # assemble .build/OnAir.app
make run           # build and launch
make install       # copy to /Applications
make uninstall     # remove the app, its Keychain items and its support directory
```

## The toolchain quirk you will hit first

**XCTest ships with Xcode, not with the Command Line Tools.** On a CLT-only machine there is no
XCTest module and no `xctest` runner, so a test target that imports XCTest cannot even build. The
whole suite is therefore written against **Swift Testing**, which CLT *does* ship — under
`Library/Developer/Frameworks`, on no default search or runtime path.

`make test` detects this and adds four flags: a framework search path, and two rpaths (one for
`Testing.framework`, one for `lib_TestingInterop.dylib` that it in turn loads). With a full Xcode
installed, `xcrun -f xctest` succeeds, the variable is empty, and `make test` is a plain
`swift test`.

Consequence: **`swift test` on its own will fail on a CLT-only machine, and `swift build
--build-tests` with it.** Use `make test`. CI does.

**SwiftLint has the same root cause, differently.** It loads SourceKit, which also ships with Xcode
— so on a CLT-only machine it does not report violations, it dies with SIGTRAP inside
`sourcekitdInProc.framework`. `make lint` recognises exactly that crash and reports it as a skip
with the reason; **any other non-zero exit still fails the gate**, because a real violation and a
missing toolchain are not the same outcome and must not look alike.

SwiftFormat has no such dependency and runs fine under CLT. Install both anyway
(`brew install swiftformat swiftlint`): CI runs SwiftLint `--strict` with a full Xcode, and it will
find what your machine could not.

## What healthy looks like

`make doctor` on a Mac with hardware:

```
OnAir doctor

Devices
  camera      MacBook Pro Camera                idle
  microphone  MacBook Pro Microphone            idle

  camera      idle
  microphone  idle

Policy
  status                :movie_camera: On camera
  watch camera          yes
  watch microphone      no
  ...

Engine
  nothing to do

Slack
  client id             built-in shared app
  user credential       present in the Keychain
  redirect URL          https://localhost:51234/callback
```

The `client id` row names where the id Connect would use comes from: `built-in shared app` once
`SlackOAuth.builtInClientID` is filled, `your own app's (pasted)` when an override shadows it, or
`missing — no built-in id in this build and none pasted` (ADR-0012).

**Read the microphone lines.** If any says `in use` while you are not in a call, something on your
Mac holds it open permanently — an audio mixer, a virtual device, a noise-suppression tool — and
turning on "Watch the microphone" would pin your status on for good. That is ADR-0011, and `doctor`
is how you find out it applies to you.

`make test` ends with a line naming the count:

```
Test run with 79 tests in 9 suites passed after 2.1 seconds.
```

The **Device journey** suite disables itself when there is no capture hardware. A CI runner has
none, so a green CI run does **not** mean those cases executed — the workflow says so out loud
rather than letting the check imply coverage it lacks.

## Exercising the real app

```bash
make run
```

Then, in order:

1. The menu bar shows a `video` glyph. Open it: on a build with no baked-in app id it says
   "Set up Slack"; with one, "Not connected".
2. Settings › Slack: if a Client ID field is shown, paste your Slack app's id — there is no
   secret; PKCE replaces it (ADR-0012) — and press Save. The runbook's §2b covers creating the app.
3. Press **Connect to Slack**. Your browser opens Slack's authorise page. Approve it, then click
   through the "connection is not private" warning — that is OnAir's own certificate for
   `localhost`, and ADR-0005 explains why it has to exist. The tab should end on "OnAir is
   connected".
4. Open Photo Booth. Within a few seconds the menu-bar glyph becomes a filled record dot and the
   panel's last line says "Set your status to On camera."
5. Quit Photo Booth. After `offDelay` the status goes back.
6. Quit OnAir mid-call and check Slack: `applicationShouldTerminate` should have put the status
   back before the process exited (ADR-0009).

## Signing

`make app` prefers a Developer ID, then an Apple Development identity, then falls back to ad-hoc
and says so. Signing is not load-bearing for permissions here — OnAir needs no TCC grant at all
(ADR-0001) — but `SMAppService` refuses to register an unsigned bundle, so **Launch at login only
works from a properly signed app**, ideally one in `/Applications`. Settings reports the failure
rather than leaving a switch that quietly does nothing.

## Residue

The loopback certificate lives at `~/Library/Application Support/OnAir/loopback.p12`, and the
Keychain items under `io.umamidata.onair` — the user token, plus a client id override if you
pasted one (ADR-0012). `make uninstall` removes the certificate and both Keychain accounts;
deleting the bundle alone leaves a live Slack token behind.
