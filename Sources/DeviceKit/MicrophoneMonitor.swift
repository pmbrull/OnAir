import CoreAudio
import Foundation

/// Whether any audio **input** device is running for some process on this Mac.
///
/// The CoreAudio mirror of `CameraMonitor`, with the same bargain: `IsRunningSomewhere` is a
/// property read, not a stream, so nothing prompts and nothing appears in Privacy & Security
/// (ADR-0001, invariant A5).
///
/// The one structural difference is that CoreAudio does not separate inputs from outputs — every
/// speaker, every aggregate, every virtual device comes back from `kAudioHardwarePropertyDevices`.
/// A device with no input streams is filtered out, because a running *output* device means music
/// is playing, which is not a meeting.
///
/// Concurrency: as `CameraMonitor` — all mutable state confined to `queue` (ADR-0003).
public final class MicrophoneMonitor: ActivityMonitor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.umamidata.onair.microphone-monitor")

    private var observed: [AudioObjectID] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var listListener: AudioObjectPropertyListenerBlock?
    private var lastReported: Bool?
    private var handler: (@Sendable (Bool) -> Void)?

    public init() {}

    deinit { detachEverything() }

    // MARK: - ActivityMonitor

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        queue.sync {
            guard self.deviceListener == nil else { return }
            self.handler = onChange

            let onDeviceChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                queue.async { self.reevaluate() }
            }
            let onListChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                queue.async {
                    self.detachFromDevices()
                    self.attachToDevices()
                    self.reevaluate()
                }
            }
            self.deviceListener = onDeviceChange
            self.listListener = onListChange

            var listAddress = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listAddress, self.queue, onListChange
            )

            self.attachToDevices()
            self.reevaluate()
        }
    }

    public func stop() {
        queue.sync {
            self.detachEverything()
            self.handler = nil
            self.lastReported = nil
        }
    }

    public func inventory() -> [CaptureDevice] {
        Self.inputDevices().map { id in
            CaptureDevice(
                kind: .microphone,
                objectID: id,
                name: Self.name(of: id),
                isRunning: Self.isRunning(id)
            )
        }
    }

    // MARK: - Queue-confined internals

    private func attachToDevices() {
        guard let block = deviceListener else { return }
        observed = Self.inputDevices()
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for id in observed {
            AudioObjectAddPropertyListenerBlock(id, &address, queue, block)
        }
    }

    private func detachFromDevices() {
        guard let block = deviceListener else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for id in observed {
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
        }
        observed = []
    }

    private func detachEverything() {
        detachFromDevices()
        if let block = listListener {
            var listAddress = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &listAddress, queue, block
            )
        }
        deviceListener = nil
        listListener = nil
    }

    private func reevaluate() {
        let value = observed.contains(where: Self.isRunning)
        guard value != lastReported else { return }
        lastReported = value
        handler?(value)
    }

    // MARK: - CoreAudio

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func inputDevices() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var byteCount: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount)
            == kAudioHardwareNoError, byteCount > 0 else { return [] }

        var ids = [AudioObjectID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, buffer.baseAddress!)
        }
        guard status == kAudioHardwareNoError else { return [] }
        return ids.filter(hasInputStreams)
    }

    /// A device is a microphone if it publishes at least one stream in the input scope. Speakers
    /// publish none, so a running output device — music, a notification sound — is excluded here
    /// rather than being mistaken for a call.
    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var address = Self.address(
            kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &byteCount) ==
            kAudioHardwareNoError
        else { return false }
        return byteCount > 0
    }

    private static func isRunning(_ id: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        // As in `CameraMonitor`: a device that will not answer is not evidence that it is running.
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) ==
            kAudioHardwareNoError
        else { return false }
        return value != 0
    }

    private static func name(of id: AudioObjectID) -> String? {
        var address = Self.address(kAudioObjectPropertyName)
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == kAudioHardwareNoError, let value = unmanaged else { return nil }
        return value.takeRetainedValue() as String
    }
}
