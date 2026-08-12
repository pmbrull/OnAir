# ADR-0004 — No third-party dependencies

- Status: Accepted
- Date: 2026-08-12

## Context

There are Swift packages for Slack's API, for keychain access, and for X.509 certificates
(`swift-certificates`). Each would remove some code from this repo.

## Decision

Foundation, AppKit, SwiftUI, Network, Security, CoreMediaIO, CoreAudio, ServiceManagement. Nothing
else. `Package.swift` has no `dependencies:` array.

## Consequences

- The whole supply chain of an app that holds a Slack token is Apple's. For a utility this small,
  that is the single largest security property available for free.
- Three Slack endpoints and a PKCS#12 import are a few hundred lines. A Slack SDK is thousands, and
  the other 95% is bot infrastructure OnAir will never call.
- The cost is real and lands in one place: minting a self-signed certificate has no public Apple
  API, so `LoopbackIdentity` shells out to `/usr/bin/openssl` rather than adding
  `swift-certificates` (ADR-0005). That trade was made deliberately and is the only one of its kind.
