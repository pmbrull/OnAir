@testable import DeviceKit
import Foundation
import Testing

/// Against **this Mac's real capture hardware**, not a fixture.
///
/// The risk `DeviceKit` carries is that CoreMediaIO and CoreAudio do not behave the way we think:
/// undocumented enumeration semantics, virtual devices from a dozen vendors, objects that appear
/// and vanish with a cable. A hand-written fake restates our belief and then agrees with it. Only
/// the real device list can falsify it (`.claude/rules/real-data-tests.md`).
///
/// The suite disables itself when there is no hardware — a CI runner has none — and says so, so a
/// green run is never mistaken for coverage it does not have.
@Suite("Device journey", .enabled(if: CaptureHardware.isPresent))
struct DeviceJourneyTests {
    /// The property OnAir is sold on: it needs no TCC grant, because it never opens a device.
    /// If enumeration ever starts requiring one, this is where it shows up — as an empty list on
    /// a machine that visibly has a camera.
    @Test("this Mac's devices enumerate without any permission prompt")
    func enumerationAnswers() {
        let devices = DeviceWatcher().inventory()
        #expect(!devices.isEmpty)

        // Per item, and named — an aggregate count would go green while a whole class of device
        // silently failed to parse.
        var unnamed: [UInt32] = []
        var zeroed: [String] = []
        for device in devices {
            if device.objectID == 0 {
                zeroed.append(device.name ?? "unnamed")
            }
            if device.name == nil {
                unnamed.append(device.objectID)
            }
        }
        #expect(zeroed.isEmpty, "devices enumerated with a null object id: \(zeroed)")
        #expect(unnamed.isEmpty, "devices that would not report a name: \(unnamed)")

        let ids = devices.map(\.objectID)
        #expect(Set(ids).count == ids.count, "the same object id was reported twice: \(ids)")
    }

    @Test("enumeration is stable across two consecutive reads")
    func enumerationIsStable() {
        let first = DeviceWatcher().inventory().map(\.objectID).sorted()
        let second = DeviceWatcher().inventory().map(\.objectID).sorted()
        #expect(first == second)
    }

    /// Two independent code paths — the per-device inventory and the live watcher — have to agree
    /// about the same hardware. They read the same property through different call sites, and a
    /// disagreement means one of them is wrong.
    @Test("the watcher's snapshot agrees with the inventory")
    func snapshotAgreesWithInventory() {
        let watcher = DeviceWatcher()
        let inventory = watcher.inventory()
        watcher.start { _ in }
        defer { watcher.stop() }

        let snapshot = watcher.snapshot
        let cameraRunning = inventory.contains { $0.kind == .camera && $0.isRunning }
        let microphoneRunning = inventory.contains { $0.kind == .microphone && $0.isRunning }

        #expect(snapshot.cameraInUse == cameraRunning)
        #expect(snapshot.microphoneInUse == microphoneRunning)
    }

    /// Not an assertion — a report. ADR-0011 turned the microphone default off because on the
    /// author's Mac an audio mixer holds two inputs open permanently, and the only way anybody
    /// finds that out about *their* machine is by being told what it currently says.
    @Test("report what this Mac's devices are doing right now")
    func reportInventory() {
        let devices = DeviceWatcher().inventory()
        for device in devices {
            let name = device.name ?? "(unnamed \(device.objectID))"
            Report
                .record(
                    "\(device.kind.rawValue): \(name) — \(device.isRunning ? "in use" : "idle")"
                )
        }
        let busyMicrophones = devices.filter { $0.kind == .microphone && $0.isRunning }
        if !busyMicrophones.isEmpty {
            Report.record(
                "microphones already in use with no call running: "
                    + busyMicrophones.map { $0.name ?? "unnamed" }.joined(separator: ", ")
                    + " — watching the microphone on this Mac would pin the status on (ADR-0011)"
            )
        }
    }
}

/// Evaluated once, at file scope rather than on the suite: a `.enabled(if:)` trait that reads a
/// static of the very type the `@Suite` macro is expanding is a circular reference the compiler
/// rejects.
private enum CaptureHardware {
    static let isPresent = !DeviceWatcher().inventory().isEmpty
}

/// Swift Testing has no "print this into the run" primitive that survives a passing test, and a
/// bare `print` is invisible under `swift test`'s reporter. Recording an expectation that always
/// holds, with the finding as its comment, is the shortest honest way to get the inventory into
/// the transcript.
private enum Report {
    static func record(_ message: String) {
        #expect(Bool(true), Comment(rawValue: message))
    }
}
