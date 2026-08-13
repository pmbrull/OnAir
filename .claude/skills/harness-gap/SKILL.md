---
name: harness-gap
description: Triggered after TWO failed attempts at the SAME task for the SAME reason. Stop, do NOT hand-write past it, record a harness gap and propose the harness fix, retry from a clean session after it lands.
---

# harness-gap

You have failed the same task twice for the same reason. The tempting third move — hand-write the
code until it passes, or loosen a check to get through — **is not available.** If the harness could
not get you there in two honest attempts, **the harness is what is wrong.** The correct output of a
failed attempt is a **harness change, not application code.**

## First, check that it really is the same reason

A step that fails several times with *different, each-time-narrower* diagnoses is converging, not
stuck. Getting Swift Testing to run under Command Line Tools took three attempts —
module-not-found → linked-but-no-rpath → wrong-rpath — and each error named the next fix exactly.
That is progress, and stopping to write a gap record would have been the wrong call.

A step that fails twice with the *same* error, or twice with two different guesses at a cause you
have not established, is stuck. A third attempt is guessing. Stop.

## Why this bites here

OnAir sits on three things nobody publishes a contract for: CoreMediaIO's and CoreAudio's
enumeration behaviour across every virtual-device vendor, Slack's JSON, and whichever LibreSSL
macOS shipped this year. When something does not work, the honest cause is usually "we do not
actually know how this behaves" — and the honest fix is to go and look, then encode what you found.
Guessing a second time produces code that works on one Mac.

## Procedure

1. **STOP.** No third attempt. Do not edit application code to force the result. Do not loosen an
   assertion.
2. **Write `docs/gaps/open/NNNN-<slug>.md`** (format in `docs/gaps/README.md`, always created in
   `open/`), then add its row to the **Open** index:
   - **Attempted** — what you tried, both times, concretely: commands, files, observed output.
   - **Could not determine** — the specific thing you lacked: a response you never captured, a
     device you do not have, a behaviour you could not reproduce.
   - **What the harness would have needed** — the missing test, tool, fixture, or doc.
   - **Proposed harness fix** — precise enough to implement.
3. **Surface it.** The harness fix is now the work — its own trip through plan → implement →
   verify → review → merge.
4. **Retry the original task from a CLEAN session** after the fix lands, so the two failed attempts
   do not bias the third.

## Explicitly not available

- Not "try harder / once more". Not "edit it directly this time". Not "the test is wrong, so loosen
  it" — if a test is genuinely wrong, fixing it *with reasoning, recorded and reviewed* is itself
  the harness change. Never a silent bypass.
- Not "it works on my Mac". One machine's audio configuration is not evidence about anyone else's;
  that is exactly the mistake ADR-0011 caught.

**A failed attempt that ends in a harness change is a success.**
