# ADR-0010 — Semantic system colours, not a palette

- Status: Accepted
- Date: 2026-08-12

## Context

Two surfaces: a menu-bar panel and a four-tab settings window. Both sit inside system chrome, in
two appearances, on displays with and without increased contrast.

## Decision

One token layer, `Sources/OnAir/Views/DesignSystem/OnAirTokens.swift`, built on AppKit's
**semantic** colours — `.windowBackgroundColor`, `.labelColor`, `.separatorColor`, the system
accent. Not a hand-picked palette.

Views draw roles, never literals: `OnAirColor`, `OnAirFont`, `OnAirMetrics`.

## Consequences

- Light and dark, increased contrast and reduced transparency all work without a second palette to
  maintain, and the panel matches the menu bar it hangs from.
- The app has no visual identity of its own beyond a red "live" dot. For a utility whose interface
  is a status indicator, matching the system *is* the design.
- The one non-semantic colour is `live` — `.systemRed`, because that is what a tally light is, and
  it is the only thing on the panel worth looking at first.
