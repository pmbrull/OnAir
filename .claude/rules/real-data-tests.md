---
paths:
  - "Sources/DeviceKit/**"
  - "Sources/SlackKit/**"
  - "Tests/**"
---

# Test the data you don't control against the data you don't control

**Constraint.** Changes under `Sources/DeviceKit/` or `Sources/SlackKit/` need coverage that
touches reality:

- **Device enumeration** → a case in `Tests/DeviceKitTests/DeviceJourneyTests.swift`, which runs
  against this Mac's real hardware and disables itself when there is none.
- **Slack parsing** → verbatim JSON captured from the real API. `SlackResponseFixtures` is the
  place, and it currently does **not** satisfy this rule — GAP-0001 is open and says so.
- **The OAuth loopback** → `LoopbackTests`, which mints a real certificate with the real
  `/usr/bin/openssl` and drives a real TLS listener with `URLSession`. A string cannot reproduce a
  certificate the TLS stack rejects.

**Why.** The risk these modules carry is that CoreMediaIO, CoreAudio, Slack, or LibreSSL is *not
what we think it is*. A hand-written fixture encodes our belief and then confirms it — it proves
the parser matches the fixture, which is the one thing never in doubt.

**This is not theoretical here.** `watchMicrophone` was going to ship `true`. Every unit test
agreed it should. One run of `make doctor` on a real Mac showed two microphones reading *in use*
with no call running, permanently, because an audio mixer holds them open — which would have pinned
this user's status on forever. No fake would ever have said that. It became ADR-0011.

**The corollary that matters.** When a parser test fails, **capture fresh real output** and update
the fixture from it. Never edit a fixture to match the code — that converts a genuine signal into a
permanent blind spot.

**Skips are not passes.** `DeviceJourneyTests` disables itself on a machine with no capture
hardware, and CI has none. A green CI run does not mean those cases executed, and the workflow
prints a notice saying so. If they skipped on your machine and you changed `DeviceKit`, you have
not verified the change.

## Assert per item, never in aggregate

A test over real data must fail on **each** item that fails and **name** it.
`#expect(devices.count > 0)` over ten devices is not a test — it is a smoke check wearing a test's
clothes, and it stays green while a whole class of device silently fails to parse.

- Loop over every item; collect failures rather than counting successes.
- Put the identifying detail in the failure message — the device name, the object id.
- When a real-data test has nothing to say, **say that out loud** rather than passing quietly.
  `DeviceJourneyTests.reportInventory` exists for this: it records what every device on the machine
  is doing right now, so the human reading the run learns what their hardware actually does.
