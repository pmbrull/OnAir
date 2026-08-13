# ADR-0001 — A menu-bar app that never opens the camera

- Status: Accepted
- Date: 2026-08-12

## Context

OnAir has to know when a camera or a microphone is in use. The obvious way is `AVCaptureSession`:
open the device, notice that you cannot, conclude somebody else has it. That approach costs a TCC
grant for the camera *and* the microphone, puts OnAir in Privacy & Security beside the apps that
actually record you, and — because macOS keys a grant to the code-signing identity — silently loses
the grant on every rebuild of an ad-hoc-signed bundle.

It is also a bad trade to offer. The pitch is "a small utility watches whether your camera is on".
A user who reads "OnAir would like to access the camera" has been asked to take a much larger
claim on trust than the feature warrants.

## Decision

**OnAir never opens a capture stream.** It reads two properties:

- `kCMIODevicePropertyDeviceIsRunningSomewhere` on each CoreMediaIO device
- `kAudioDevicePropertyDeviceIsRunningSomewhere` on each CoreAudio input device

Both answer for *every* process, not just this one, and both are property reads that need no
authorisation. This is invariant **A5**, and `scripts/check-architecture.sh` fails the build on
`AVCaptureSession`, `AVCaptureDevice`, `CMSampleBuffer`, `AudioDeviceStart`, `AVAudioEngine` and
friends anywhere in `Sources/`, and on an `NSCameraUsageDescription` key in `Resources/`. CI
re-checks the assembled bundle's plist, because the property has to hold in the artefact and not
only in the sources.

The app is menu-bar only (`LSUIElement`): it has no document, no window worth a Dock icon, and its
entire interface is a state indicator.

## Consequences

- No permission prompt, ever. Nothing to grant, nothing to lose on rebuild, nothing in
  Privacy & Security. Verified: `onair doctor` enumerated ten devices on an unsigned debug build
  with no TCC entry of any kind.
- OnAir cannot tell you *which* app is using the camera, only that something is. Attributing the
  use to a process would need exactly the privileges this decision refuses.
- The claim is checkable by anyone: the greps are in the repo and run on every commit.

## Alternatives

- **`AVCaptureSession` probing** — rejected above.
- **Parsing `log stream` for camera events** — needs no permission either, but it means depending
  on the wording of Apple's private log messages, spawning a long-lived subprocess, and reading a
  stream that carries every other app's diagnostics through this process.
