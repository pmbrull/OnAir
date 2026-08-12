# ADR-0002 — Headless kits, a thin app shell

- Status: Accepted
- Date: 2026-08-12

## Context

The app target cannot be unit-tested in this package: there is no test target for an executable
that owns `NSApplication`, and SwiftUI views are not where logic should be proved. Whatever lives
in `Sources/OnAir/` is, in practice, unverified.

## Decision

Three libraries, each importing no UI framework, and one thin executable:

| Target | Owns |
|---|---|
| `DeviceKit` | is a camera or a microphone running |
| `StatusKit` | the policy: debounce, pause, override, ownership. Depends on nothing |
| `SlackKit` | Slack's Web API and the OAuth loopback. Depends on `StatusKit` for `UserStatus` |
| `OnAir` | menu bar, Settings, Keychain, login item, wiring |

`scripts/check-architecture.sh` enforces both halves: no kit imports AppKit, SwiftUI, Cocoa, UIKit
or ServiceManagement (**A2**), and the dependency edges are one-way with `SlackKit → StatusKit` as
the single permitted sibling edge (**A1**).

## Consequences

- Everything that decides anything is testable in milliseconds without hardware or a network.
- The app target is small enough to read in one sitting, and what it does is *perform*, never
  decide (**A3**).
- `SlackKit → StatusKit` looks backwards until you notice that `UserStatus` is the domain type both
  sides speak. The alternative — a `SlackStatus` type in `SlackKit` and a mapping layer — is two
  near-identical structs and a function that can be wrong.
