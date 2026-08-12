import Foundation

/// One class of capture hardware, and whether any of it is streaming to *some* process.
///
/// The protocol exists so `DeviceWatcher` — where the composition logic lives — can be tested
/// without hardware. The two real implementations are `CameraMonitor` and `MicrophoneMonitor`.
public protocol ActivityMonitor: AnyObject, Sendable {
    /// Installs listeners and reports the state.
    ///
    /// `onChange` is called **once immediately** with the current value, then on every change.
    /// It is always called on a private serial queue, never the main thread — a caller that
    /// touches UI must hop itself.
    func start(onChange: @escaping @Sendable (Bool) -> Void)

    func stop()

    /// A one-shot read that installs nothing. What `onair doctor` prints.
    func inventory() -> [CaptureDevice]
}

/// One device as the hardware reports it. Used by `onair doctor`, which is how you find out that
/// a Mac has four "cameras" and that the one lighting up is Continuity Camera.
public struct CaptureDevice: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case camera
        case microphone
    }

    public let kind: Kind
    public let objectID: UInt32
    /// `nil` when the device declined to name itself, rather than a placeholder — an invented
    /// name in a diagnostic is worse than an absent one (`.claude/rules/no-silent-fallbacks.md`).
    public let name: String?
    public let isRunning: Bool

    public init(kind: Kind, objectID: UInt32, name: String?, isRunning: Bool) {
        self.kind = kind
        self.objectID = objectID
        self.name = name
        self.isRunning = isRunning
    }
}
