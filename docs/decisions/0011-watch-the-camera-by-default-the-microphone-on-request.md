# ADR-0011 — Watch the camera by default, the microphone only on request

- Status: Accepted
- Date: 2026-08-12

## Context

The brief asked for camera *and* microphone, with either one setting the status. Both were built,
and the default was going to be both on.

Then `onair doctor` was run against the author's actual Mac:

```
microphone  Yeti Stereo Microphone            in use
microphone  MacBook Pro Microphone            in use
```

with no call running, no meeting app open, and stably across repeated reads.
`pgrep` found the cause: `Elgato Wave Link.app --run-in-background`, an audio mixer that holds both
inputs open around the clock. `kAudioDevicePropertyDeviceIsRunningSomewhere` is telling the truth —
those devices *are* running somewhere.

Wave Link is not unusual. Loopback, BlackHole, Krisp, SoundSource, most USB interface control
panels and macOS dictation all behave the same way. The camera has no equivalent: nothing holds one
open for hours, which is why the green dot is trustworthy and a microphone-in-use signal is not.

## Decision

`StatusPolicy.standard.watchMicrophone = false`. `watchCamera` stays `true`. The capability is
unchanged and one toggle away in Settings › Behaviour, which explains the reason and points at
`onair doctor` as the way to find out whether it is safe on *this* machine.

## Consequences

- Out of the box OnAir does what its name says and nothing surprising. A default of "on" would have
  pinned this user's status to "On camera" permanently, which is worse than the feature being off.
- Audio-only calls do not set a status unless the user opts in. `doctor` reports every device and
  flags microphones already in use, so the decision is informed rather than guessed at.
- This is why `doctor` exists. Nothing in the design predicted it and no unit test could have; it
  took one run against real hardware (`.claude/rules/real-data-tests.md`).
