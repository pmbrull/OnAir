# ADR-0003 — Property listeners over polling

- Status: Accepted
- Date: 2026-08-12

## Context

`IsRunningSomewhere` can be polled or observed. Polling every 500ms is the shape most examples
online use, and it is simple. Observing means `CMIOObjectAddPropertyListenerBlock` /
`AudioObjectAddPropertyListenerBlock`, plus a second listener on the device *list* so hardware
plugged in later is not invisible.

## Decision

Listeners, on a private serial `DispatchQueue` per monitor, plus a device-list listener that
detaches and re-attaches on any change.

Both monitors are `@unchecked Sendable` `final class`es whose every mutable field is confined to
that queue. An `actor` would be the tidier-looking choice, but the C API takes a `DispatchQueue`
and delivers on it, so an actor adds a hop per notification for isolation the queue already
provides — and the `@unchecked` is justified in a comment at the declaration, which is the bargain
the reviewer rule asks for.

## Consequences

- No wakeups on an idle laptop, and a reaction in milliseconds rather than up to half a second.
- Hot-plugging a webcam mid-call works. This is not hypothetical on a Mac: Continuity Camera
  appears and disappears with the phone.
- CoreMediaIO fires once **per device**, so one camera starting produces several notifications on a
  machine with four video objects. Both monitors coalesce, and `DeviceWatcher` drops a snapshot
  identical to the last one. Without that, a single event would wake the engine four times.
