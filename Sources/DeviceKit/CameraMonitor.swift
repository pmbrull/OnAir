import CoreMediaIO
import Foundation

/// Whether any video device is streaming to some process on this Mac.
///
/// `kCMIODevicePropertyDeviceIsRunningSomewhere` answers that **without opening the device**,
/// which is the whole reason OnAir needs no camera permission and never appears in the
/// Privacy & Security pane (ADR-0001, invariant A5). It also answers for *every* process, not
/// just this one, which is what makes the question useful at all.
///
/// All mutable state is confined to `queue`: every entry point hops onto it with `sync`, and
/// CoreMediaIO delivers its callbacks on it because it was handed the queue. `@unchecked Sendable`
/// rather than an `actor` because the C API takes a `DispatchQueue` and an actor would add a hop
/// per notification for isolation the queue already provides (ADR-0003).
public final class CameraMonitor: ActivityMonitor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.umamidata.onair.camera-monitor")

    private var observed: [CMIOObjectID] = []
    private var deviceListener: CMIOObjectPropertyListenerBlock?
    private var listListener: CMIOObjectPropertyListenerBlock?
    private var lastReported: Bool?
    private var handler: (@Sendable (Bool) -> Void)?

    public init() {}

    deinit { detachEverything() }

    // MARK: - ActivityMonitor

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        queue.sync {
            guard self.deviceListener == nil else { return }
            self.handler = onChange

            // One block shared by every device: `CMIOObjectRemovePropertyListenerBlock` matches on
            // block identity, so a fresh closure per device would be unremovable.
            let onDeviceChange: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                queue.async { self.reevaluate() }
            }
            // A webcam plugged in mid-call is a new object with no listener on it. Without this,
            // OnAir would watch the devices that existed at launch and nothing else.
            let onListChange: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                queue.async {
                    self.detachFromDevices()
                    self.attachToDevices()
                    self.reevaluate()
                }
            }
            self.deviceListener = onDeviceChange
            self.listListener = onListChange

            var listAddress = Self.address(kCMIOHardwarePropertyDevices)
            CMIOObjectAddPropertyListenerBlock(
                CMIOObjectID(kCMIOObjectSystemObject), &listAddress, self.queue, onListChange
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
        Self.systemDevices().map { id in
            CaptureDevice(
                kind: .camera,
                objectID: id,
                name: Self.name(of: id),
                isRunning: Self.isRunning(id)
            )
        }
    }

    // MARK: - Queue-confined internals

    private func attachToDevices() {
        guard let block = deviceListener else { return }
        observed = Self.systemDevices()
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for id in observed {
            CMIOObjectAddPropertyListenerBlock(id, &address, queue, block)
        }
    }

    private func detachFromDevices() {
        guard let block = deviceListener else { return }
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for id in observed {
            CMIOObjectRemovePropertyListenerBlock(id, &address, queue, block)
        }
        observed = []
    }

    private func detachEverything() {
        detachFromDevices()
        if let block = listListener {
            var listAddress = Self.address(kCMIOHardwarePropertyDevices)
            CMIOObjectRemovePropertyListenerBlock(
                CMIOObjectID(kCMIOObjectSystemObject), &listAddress, queue, block
            )
        }
        deviceListener = nil
        listListener = nil
    }

    /// Coalesces: CoreMediaIO fires once per device, so a single camera starting can produce
    /// several notifications that all resolve to the same answer.
    private func reevaluate() {
        let value = observed.contains(where: Self.isRunning)
        guard value != lastReported else { return }
        lastReported = value
        handler?(value)
    }

    // MARK: - CoreMediaIO

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func systemDevices() -> [CMIOObjectID] {
        var address = Self.address(kCMIOHardwarePropertyDevices)
        var byteCount: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount)
            == OSStatus(kCMIOHardwareNoError), byteCount > 0 else { return [] }

        var ids = [CMIOObjectID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<CMIOObjectID>.size
        )
        var used: UInt32 = 0
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            CMIOObjectGetPropertyData(
                system,
                &address,
                0,
                nil,
                byteCount,
                &used,
                buffer.baseAddress!
            )
        }
        guard status == OSStatus(kCMIOHardwareNoError) else { return [] }
        return ids
    }

    private static func isRunning(_ id: CMIOObjectID) -> Bool {
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(id, &address, 0, nil, size, &used, &value)
        // A device that will not answer is not evidence that it is running. Reporting `true` here
        // would set a status because a virtual camera misbehaved.
        guard status == OSStatus(kCMIOHardwareNoError) else { return false }
        return value != 0
    }

    private static func name(of id: CMIOObjectID) -> String? {
        var address = Self.address(kCMIOObjectPropertyName)
        var unmanaged: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            CMIOObjectGetPropertyData(id, &address, 0, nil, size, &used, pointer)
        }
        guard status == OSStatus(kCMIOHardwareNoError), let value = unmanaged else { return nil }
        return value.takeRetainedValue() as String
    }
}
