---
paths:
  - "**/*.swift"
---

# Comment the *why*, never the *what*

**Constraint (advisory — not mechanically checkable).** Write a comment only when the code cannot
carry the information itself. A comment that restates *what* the code does is a smell: delete it
and rename until the code says it. Reserve comments for the *why* the code can't express — a
non-obvious constraint, a deliberate deviation, an ADR or gap reference, or a "this looks wrong but
isn't".

**Why.** Comments rot silently; `// increment i` is pure liability. The *why* behind a decision is
exactly what a future reader cannot reconstruct from the code.

**This repo has an unusual amount of legitimate *why*, and almost all of it was measured rather
than reasoned.** The microphone default is off because an audio mixer holds the input open
(ADR-0011). The OAuth listener speaks plain HTTP because a page we host, not this machine, is
Slack's redirect URL (ADR-0019). The relay page forwards a named set of parameters rather than the
whole query string, because it is handing them to a listener that is about to decide whether to
trust them. Both device monitors coalesce because CoreMediaIO fires once per device. Every one of those looks like
over-engineering until you know the failure it prevents. **Say the failure.**

The inverse is equally a finding: a workaround with no explanation is a line the next person will
delete.

**Comment vs. ADR.** Once a comment survives the *why* test, ask where it belongs. A *why* tied to
this exact line stays. A decision with alternatives, consequences and a date goes to
`docs/decisions/` — and the line keeps a one-line summary plus the ADR tag, not the whole argument.

**Reviewer rule.** `convention-reviewer` flags comments that restate the code, and code whose *why*
is missing.
