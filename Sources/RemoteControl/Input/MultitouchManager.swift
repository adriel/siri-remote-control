import CShims
import Foundation
import IOKit
import RemoteCore

/// Reads the Siri Remote's touch surface.
///
/// macOS exposes the remote's digitizer as an `AppleMultitouchDevice` under an
/// `AppleEmbeddedBluetoothTouch` driver. MultitouchSupport (the private framework that also
/// powers trackpads) delivers per-finger contact frames for it.
@MainActor
final class MultitouchManager: ObservableObject {
    static let shared = MultitouchManager()

    @Published private(set) var attachedCount = 0
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var loadError: String?

    var onFrame: (([TouchSample], TimeInterval) -> Void)?
    /// (new state, old state): the clickpad's mechanical click, reported alongside touch data.
    var onButtonState: ((UInt32, UInt32) -> Void)?

    private let log = DiagnosticsLog.shared
    private var devices: [UInt64: MTDeviceRef] = [:]
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var running = false

    func start() {
        guard !running else { return }
        guard CMTLoad() else {
            loadError = String(cString: CMTLoadError())
            log.add(.error, .touch, "Touch input unavailable: \(loadError ?? "unknown error")")
            return
        }
        loadError = nil
        running = true

        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"), { context, iterator in
            guard let context else { return }
            let me = Unmanaged<MultitouchManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.servicesAppeared(iterator) }
        }, context, &addedIterator)
        servicesAppeared(addedIterator)

        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"), { context, iterator in
            guard let context else { return }
            let me = Unmanaged<MultitouchManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.servicesTerminated(iterator) }
        }, context, &removedIterator)
        servicesTerminated(removedIterator)
    }

    func stop() {
        guard running else { return }
        running = false
        for (_, device) in devices { detach(device) }
        devices.removeAll()
        attachedCount = 0
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    /// Re-attaches to every remote touch surface, e.g. after the remote woke up.
    func rescan() {
        stop()
        start()
    }

    fileprivate func deliver(_ samples: [TouchSample], at time: TimeInterval) {
        lastFrameAt = Date()
        onFrame?(samples, time)
    }

    fileprivate func deliverButtonState(new: UInt32, old: UInt32) {
        onButtonState?(new, old)
    }

    // MARK: - IOKit notifications

    private func servicesAppeared(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard Self.isRemoteTouchSurface(service) else { continue }
            let id = Self.registryID(service)
            guard devices[id] == nil else { continue }
            attach(service: service, id: id, attempt: 0)
        }
    }

    private func servicesTerminated(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let id = Self.registryID(service)
            if let device = devices.removeValue(forKey: id) {
                detach(device)
                attachedCount = devices.count
                log.add(.info, .touch, "Touch surface detached")
            }
        }
    }

    private func attach(service: io_service_t, id: UInt64, attempt: Int) {
        guard let device = CMTDeviceCreateFromService(service) else {
            // The multitouch stack can lag the IOKit node by a moment after the remote reconnects.
            if attempt < 5 {
                IOObjectRetain(service)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    defer { IOObjectRelease(service) }
                    guard let self, self.running, self.devices[id] == nil else { return }
                    self.attach(service: service, id: id, attempt: attempt + 1)
                }
            } else {
                log.add(.error, .touch, "Couldn't open the remote's touch surface")
            }
            return
        }
        CMTRegisterContactFrameCallback(device, contactFrameCallback)
        if !CMTRegisterButtonStateCallback(device, buttonStateCallback, nil) {
            log.add(.warning, .touch, "Couldn't register for clickpad clicks")
        }
        let status = CMTDeviceStart(device, 0)
        devices[id] = device
        attachedCount = devices.count
        if status == 0 {
            log.add(.success, .touch, "Touch surface attached")
        } else {
            log.add(.warning, .touch, "Touch surface attached but MTDeviceStart returned \(status)")
        }
    }

    private func detach(_ device: MTDeviceRef) {
        CMTUnregisterContactFrameCallback(device, contactFrameCallback)
        CMTUnregisterButtonStateCallback(device, buttonStateCallback)
        if CMTDeviceIsRunning(device) { _ = CMTDeviceStop(device) }
        CMTDeviceRelease(device)
    }

    private static func isRemoteTouchSurface(_ service: io_service_t) -> Bool {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<4 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(parent, "AppleEmbeddedBluetoothTouch") != 0 { return true }
        }
        return false
    }

    private static func registryID(_ service: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }
}

/// Runs on MultitouchSupport's private thread; hops to the main thread with a copy of the frame.
private let contactFrameCallback: CMTContactCallback = { _, touches, count, _, _ in
    var samples: [TouchSample] = []
    if let touches, count > 0 {
        samples.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let t = touches[i]
            samples.append(TouchSample(
                id: t.pathIndex,
                x: Double(t.normalized.position.x),
                y: Double(t.normalized.position.y),
                isTouching: t.state == 3 || t.state == 4
            ))
        }
    }
    let now = ProcessInfo.processInfo.systemUptime
    DispatchQueue.main.async {
        MainActor.assumeIsolated { MultitouchManager.shared.deliver(samples, at: now) }
    }
    return 0
}

/// The Siri Remote's clickpad has one mechanical switch. Its click arrives here, not in the HID button report.
private let buttonStateCallback: CMTButtonStateCallback = { _, newState, oldState, _ in
    DispatchQueue.main.async {
        MainActor.assumeIsolated { MultitouchManager.shared.deliverButtonState(new: newState, old: oldState) }
    }
}
