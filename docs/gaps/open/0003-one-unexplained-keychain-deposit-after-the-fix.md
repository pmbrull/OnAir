---
id: GAP-0003
title: One run deposited seven keychain items after the ADR-0016 fix, and nothing has reproduced it
status: open
impact: leaves a residual doubt that ADR-0016 closes every path to the login keychain, not just the one that was measured
opened: 2026-08-14
closed_by:
---

**Question.** During the verification sweep for ADR-0016, one `make verify` run added **7 private
keys and 7 `localhost` certificates** to the login keychain *after* the `kSecImportToMemoryOnly` fix
was in place. Nothing since has reproduced it. Is there a second path into the keychain that the fix
does not cover, or was that run executing pre-fix code for a reason not identified?

**Why it's open.** The measurements around it are clean and the anomaly is not:

| Run | Keys before → after | Exit |
|---|---|---|
| Two verifies, sequential | 345 → 345 → **352** | 0, then **2** |
| Three verifies, sequential | 352 → 352 → 352 → 352 | 0, 0, 0 |
| Four full `make test` runs | 352 throughout | 0 ×4 |
| Two forced rebuilds (`touch` both sources) then verify | 352 → 352 | 0, 0 |
| Five samples at rest, no activity | 352 throughout | — |
| Per-test measurement, each of five loopback tests | delta 0 each | — |

So: nine clean runs either side, a stable count at rest, and one run in the middle that moved it by
7. In the anomalous run the leak test itself failed — but only on the certificate count
(347 → 348) and **not** on the key count, meaning six of the seven keys landed outside the window
the test measures. The leak test runs second in a serialised suite, and no other suite in the
project imports a PKCS#12.

**7 is the number that makes this worth recording rather than shrugging off.** `LoopbackTests` mints
eight archives per run, and eight archives is what the pre-fix code would have deposited. That is
consistent with the run having executed pre-fix code — but the obvious mechanism does not hold up:
the anomalous run and the clean run before it both recompiled (56 "Compiling" lines each), and
deliberately forcing a rebuild twice more did not reproduce it.

A plausible story exists — a transitional build state during the session in which the fix landed —
and it is exactly the kind of story this repo's escape-hatch rule says not to write down as though
it were measured. It is not measured. It is a guess that fits.

**Blocks.** Nothing. ADR-0016 stands on its own evidence: the mechanism is understood, the fix is
verified by direct probe and by a regression test, and the steady state across nine runs is zero
drift. What is unresolved is whether the guarantee is *total*.

**Provisional handling.** Shipped as is, with three things carrying the doubt:

- The regression test in `LoopbackTests` fails on a non-zero delta, so a returning leak surfaces in
  the gate rather than in someone's keychain months later — which is how this was found in the
  first place.
- Invariant A6 in `scripts/check-architecture.sh` fails the build on a `SecPKCS12Import(` call site
  without `kSecImportToMemoryOnly`.
- `make purge-loopback` reports what is present, so the count is checkable at any time without
  deleting anything.

**How to close it.** Run `make purge-loopback` after a few weeks of ordinary use. A report of zero
closes this as a transitional artefact. A report of anything else means there is a second path, and
the next thing to instrument is what runs between a verify's start and the loopback suite's second
test — the window six of the seven keys landed in.
