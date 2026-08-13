import Foundation

/// What the hardware is doing, as one value.
public struct DeviceSnapshot: Sendable, Equatable {
    public var cameraInUse: Bool
    public var microphoneInUse: Bool

    public init(cameraInUse: Bool = false, microphoneInUse: Bool = false) {
        self.cameraInUse = cameraInUse
        self.microphoneInUse = microphoneInUse
    }

    public static let idle = DeviceSnapshot()
}

/// Both monitors, joined into a single stream of snapshots.
///
/// Deliberately dumb: it reports what the hardware says and holds no opinion about what should
/// follow. Whether a running microphone alone means "in a meeting" is a *policy* question, and
/// policy lives in `StatusKit` (invariant A3) — which is what lets every rule worth arguing about
/// be tested without a webcam.
public final class DeviceWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.umamidata.onair.device-watcher")
    private let camera: any ActivityMonitor
    private let microphone: any ActivityMonitor

    private var current = DeviceSnapshot.idle
    private var handler: (@Sendable (DeviceSnapshot) -> Void)?

    public init(
        camera: any ActivityMonitor = CameraMonitor(),
        microphone: any ActivityMonitor = MicrophoneMonitor()
    ) {
        self.camera = camera
        self.microphone = microphone
    }

    /// `onChange` fires on a private serial queue for every distinct snapshot, including the
    /// first. A caller that touches UI must hop to the main actor itself.
    public func start(onChange: @escaping @Sendable (DeviceSnapshot) -> Void) {
        queue.sync { self.handler = onChange }
        camera.start { [weak self] value in
            self?.apply { $0.cameraInUse = value }
        }
        microphone.start { [weak self] value in
            self?.apply { $0.microphoneInUse = value }
        }
    }

    public func stop() {
        camera.stop()
        microphone.stop()
        queue.sync {
            self.handler = nil
            self.current = .idle
        }
    }

    public var snapshot: DeviceSnapshot {
        queue.sync { current }
    }

    public func inventory() -> [CaptureDevice] {
        camera.inventory() + microphone.inventory()
    }

    /// Serialised so a camera and a microphone changing in the same instant cannot interleave into
    /// a snapshot that never existed — the two monitors run on different queues.
    private func apply(_ mutate: @escaping @Sendable (inout DeviceSnapshot) -> Void) {
        queue.async {
            var next = self.current
            mutate(&next)
            guard next != self.current else { return }
            self.current = next
            self.handler?(next)
        }
    }
}
