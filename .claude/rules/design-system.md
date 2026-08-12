---
paths:
  - "Sources/OnAir/Views/**"
---

# Draw from the tokens

**Constraint.** Every colour, font and metric in `Sources/OnAir/Views/` comes from
`Views/DesignSystem/OnAirTokens.swift`. A literal `Color(...)`, `.font(.system(size:))`,
`.foregroundStyle(.secondary)` or a bare corner radius outside that file is a violation — and so is
a new token added because one screen wanted a shade. A token is a role the whole app shares.

**Why.** Two appearances multiply every decision, and OnAir's surfaces hang off the menu bar where
being half a step off the system is immediately visible. The tokens are built on AppKit's
**semantic** colours precisely so light, dark, increased contrast and reduced transparency all work
without a second palette to maintain (ADR-0010).

This rule is deliberately shorter than the equivalent in a design-led app. OnAir has two small
surfaces and no visual identity to defend beyond one red dot. Keep it that way: a token layer that
grows faster than the app is ceremony.

## Spend the accent

The only non-semantic colour is `live` — `.systemRed`, because that is what a tally light is. It
means "a device is running" and nothing else. A second red element on the panel competes with the
one thing worth looking at first.

`success` / `warning` / `danger` report a **state the user can act on**, never decoration. A colour
used because a row looked plain is the one to delete.

## Controls keep their behaviour

**Anything clickable is a `Button` with a `ButtonStyle`, never a styled `HStack` with
`.onTapGesture`.** A tappable rectangle silently drops focus, Return-to-activate and its VoiceOver
role, and the loss is invisible in a screenshot — which is exactly how a restyle regresses
accessibility. Decorative shapes (`StatusDot`, `Hairline`) carry `.accessibilityHidden(true)`,
because the row's text already says what the dot says and hearing it twice is worse than not
hearing it.

**Do not declare `@State` or `@Environment` on a `ButtonStyle`.** SwiftUI does not install property
wrappers there — the style is a value re-made on every evaluation — so the state never updates and
the bug is silent. Put them on a nested `View` that `makeBody` returns.

## Never draw what the app cannot know

A control wired to nothing, or a value the app cannot determine, does not get drawn. This is
`no-silent-fallbacks.md` reaching the surface: a user believes a rendered toggle, and a mocked one
is a lie told in the most convincing place available.

**Reviewer rule.** `convention-reviewer` flags literals outside `DesignSystem/`, a second use of
`live`, a tappable non-`Button`, and property wrappers declared on a `ButtonStyle`.
