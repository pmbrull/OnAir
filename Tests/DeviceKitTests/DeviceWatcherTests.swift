@testable import DeviceKit
import Foundation
import Testing

/// A monitor the test drives by hand, so the composition in `DeviceWatcher` can be checked without
/// a webcam and without waiting for anything.
private final class FakeMonitor: ActivityMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?
    private let initial: Bool

    init(initial: Bool = false) {
        self.initial = initial
    }

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        handler = onChange
        lock.unlock()
        // The real monitors report the current value immediately; a fake that did not would let
        // a bug where the first value is dropped pass unnoticed.
        onChange(initial)
    }

    func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func inventory() -> [CaptureDevice] {
        []
    }

    func fire(_ value: Bool) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(value)
    }
}

@Suite("Device watcher")
struct DeviceWatcherTests {
    /// `snapshot` reads through the watcher's own serial queue, so it is a barrier: any change
    /// already dispatched has been applied by the time it returns. That is what makes these tests
    /// deterministic instead of sleep-based.
    private func makeWatcher(
        camera: FakeMonitor,
        microphone: FakeMonitor
    ) -> (DeviceWatcher, Recorder) {
        let watcher = DeviceWatcher(camera: camera, microphone: microphone)
        let recorder = Recorder()
        watcher.start { recorder.record($0) }
        return (watcher, recorder)
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [DeviceSnapshot] = []

        func record(_ snapshot: DeviceSnapshot) {
            lock.lock()
            values.append(snapshot)
            lock.unlock()
        }

        var all: [DeviceSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    @Test("a camera coming on shows up in the snapshot")
    func cameraOn() {
        let camera = FakeMonitor()
        let (watcher, _) = makeWatcher(camera: camera, microphone: FakeMonitor())
        defer { watcher.stop() }

        camera.fire(true)
        #expect(watcher.snapshot == DeviceSnapshot(cameraInUse: true, microphoneInUse: false))
    }

    @Test("the two sources are tracked independently")
    func bothSources() {
        let camera = FakeMonitor()
        let microphone = FakeMonitor()
        let (watcher, _) = makeWatcher(camera: camera, microphone: microphone)
        defer { watcher.stop() }

        microphone.fire(true)
        #expect(watcher.snapshot == DeviceSnapshot(cameraInUse: false, microphoneInUse: true))
        camera.fire(true)
        #expect(watcher.snapshot == DeviceSnapshot(cameraInUse: true, microphoneInUse: true))
        microphone.fire(false)
        #expect(watcher.snapshot == DeviceSnapshot(cameraInUse: true, microphoneInUse: false))
    }

    /// CoreMediaIO fires once per device, so one camera starting on a Mac with four video objects
    /// produces four notifications that all mean the same thing. Passing each of them on would
    /// wake the engine — and potentially Slack — several times per event.
    @Test("repeating the same value emits nothing")
    func duplicatesAreDropped() {
        let camera = FakeMonitor()
        let (watcher, recorder) = makeWatcher(camera: camera, microphone: FakeMonitor())
        defer { watcher.stop() }

        camera.fire(true)
        camera.fire(true)
        camera.fire(true)
        _ = watcher.snapshot
        #expect(recorder.all.count == 1)
    }

    @Test("an initial true is reported rather than swallowed")
    func initialValueIsReported() {
        let camera = FakeMonitor(initial: true)
        let (watcher, recorder) = makeWatcher(camera: camera, microphone: FakeMonitor())
        defer { watcher.stop() }

        _ = watcher.snapshot
        #expect(recorder.all == [DeviceSnapshot(cameraInUse: true)])
    }

    @Test("stopping clears the snapshot and detaches")
    func stopping() {
        let camera = FakeMonitor()
        let (watcher, recorder) = makeWatcher(camera: camera, microphone: FakeMonitor())

        camera.fire(true)
        #expect(watcher.snapshot.cameraInUse)

        watcher.stop()
        #expect(watcher.snapshot == .idle)

        let before = recorder.all.count
        camera.fire(true)
        _ = watcher.snapshot
        #expect(recorder.all.count == before, "a stopped watcher must not still be reporting")
    }
}
