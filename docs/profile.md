# Project profile

The constraints every decision is scaled to. When an ADR and this document disagree, the ADR is
newer and wins — then update this.

## Shape

A single-user macOS desktop utility. No server, no accounts, no multi-tenancy. The only remote
traffic is six Slack Web API calls on the user's own behalf.

## Stack

- **Swift 6 / SwiftPM**, no external dependencies (ADR-0004).
- **AppKit + SwiftUI**, menu-bar only (`LSUIElement`).
- **CoreMediaIO + CoreAudio** property listeners for device activity (ADR-0003).
- **Network.framework** for the TLS loopback that catches Slack's OAuth redirect (ADR-0005).
- **Security** for the Keychain, PKCS#12 import and the PKCE verifier's randomness; **CryptoKit**
  for its S256 challenge (ADR-0012); **ServiceManagement** for the login item.

## Team

**TEAM = 1.** Solo. Review is self-review by subagents, advisory. An agent opens PRs and never
merges.

Two automated gates, split by cost. **Pre-commit hooks** run the greps, the formatter, the linter
and an incremental build — everything fast enough that nobody reaches for `--no-verify`.
**GitHub Actions** runs the full suite and assembles the bundle on every PR. Neither is a substitute
for the device journey tests, which need real capture hardware and therefore a real machine.

## Verification bar

- `make verify` green is necessary, never sufficient.
- Anything touching device enumeration is verified **against this Mac's real hardware**, by effect —
  `make doctor` and `DeviceJourneyTests`.
- Anything parsing Slack's JSON is verified against **verbatim captured output**. Today it is not:
  see GAP-0001, which says so out loud rather than letting the tests imply coverage they lack.
- Runtime behaviour is exercised in the real app before a PR opens.

ADR-0011 is the standing argument for this bar. The microphone default was going to be "on"; one
run of `make doctor` against real hardware showed the microphone reads *in use* permanently on this
machine, and no unit test in the world would have caught it.

## Forbidden

1. **Opening a capture stream.** OnAir reads "is running" and nothing else (ADR-0001, A5).
2. **A credential anywhere but the Keychain** — not `UserDefaults`, not a file, not a log line, not
   an interpolated string (ADR-0006, A4).
3. **A client secret anywhere in the system** — none is compiled in, pasted in, or stored; PKCE
   replaces it (ADR-0012).
4. **Shell string interpolation for subprocesses.** Argument arrays only.
5. **Any off-machine transmission other than the Slack calls themselves.** No telemetry, no
   analytics, no crash reporting.
6. **Filling an unknown with a plausible value** instead of reporting that it is unknown.
7. **Overwriting a status OnAir did not set**, unless the user asked for that (ADR-0008).

## Deliberately not built

| Thing | Trigger to build it |
|---|---|
| Multiple Slack workspaces | a second workspace is actually used daily |
| Per-app rules (only Zoom, only Meet) | the camera signal proves too coarse in practice |
| `status_expiration` **of OnAir's own choosing** as a crash net (it does carry back one it read — ADR-0015) | a stranded status actually happens (ADR-0009) |
| Screen-sharing detection | the camera signal misses enough presentations to notice |
| Do Not Disturb alongside the status | wanting it, and accepting the extra `dnd:write` scope |
