import Foundation
import IOKit
import IOKit.hid
import RemoteCore

/// Watches for Siri Remotes and reads their button reports.
///
/// The remote's button interface is opened with `kIOHIDOptionsTypeSeizeDevice` when exclusive access is on.
/// Then macOS's own handling (system volume, Music launching on Play, and so on) doesn't fire alongside ours.
@MainActor
final class HIDRemoteManager: ObservableObject {
    struct RemoteDevice: Identifiable, Equatable {
        let id: UInt64              // IORegistry entry ID of the HID device
        let productID: Int
        let name: String            // HID product string (the remote reports its serial here)
        let address: String         // Bluetooth address (HID serial number)
        let modelName: String
        var openResult: IOReturn
        var exclusive: Bool
        let connectedAt: Date

        var isOpen: Bool { openResult == kIOReturnSuccess }
    }

    @Published private(set) var devices: [RemoteDevice] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastDisconnect: Date?
    /// Logs every raw report and element value from the remote (Diagnostics → Log raw input).
    @Published var rawLogging = UserDefaults.standard.bool(forKey: "rawInputLogging") {
        didSet {
            UserDefaults.standard.set(rawLogging, forKey: "rawInputLogging")
            rawLogger.setEnabled(rawLogging)
        }
    }

    /// (button or nil if the usage isn't mapped, raw usage, pressed)
    var onButton: ((RemoteButton?, HIDUsage, Bool) -> Void)?
    var onDeviceConnected: ((RemoteDevice) -> Void)?
    var onDeviceDisconnected: ((RemoteDevice) -> Void)?

    private let log = DiagnosticsLog.shared
    private var manager: IOHIDManager?
    private var openDevices: [UInt64: IOHIDDevice] = [:]
    private var pressedUsages: [UInt64: Set<HIDUsage>] = [:]
    /// Remotes that matched but couldn't be opened (usually another app holds them). Retried periodically.
    private var pendingDevices: [UInt64: IOHIDDevice] = [:]
    private var retryTimer: Timer?
    private var wantExclusive = true
    private var reportBuffers: [UInt64: (pointer: UnsafeMutablePointer<UInt8>, size: Int)] = [:]
    private let rawLogger = RawInputLogger()

    func start(exclusive: Bool) {
        if isRunning, exclusive == wantExclusive { return }
        stop()
        wantExclusive = exclusive

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: SiriRemoteHID.vendorID,
            kIOHIDTransportKey: SiriRemoteHID.transport,
            kIOHIDPrimaryUsagePageKey: kHIDPage_Consumer,
            kIOHIDPrimaryUsageKey: kHIDUsage_Csmr_ConsumerControl,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<HIDRemoteManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceMatched(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<HIDRemoteManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceRemoved(device) }
        }, context)
        // Common modes so presses still arrive while a menu is open.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
        isRunning = true
        log.add(.info, .device, "Watching for Siri Remotes (\(exclusive ? "exclusive" : "shared") access)")
        rawLogger.setEnabled(rawLogging)
    }

    func stop() {
        rawLogger.setEnabled(false)
        for (id, device) in openDevices {
            releaseAllPressed(deviceID: id)
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            if let buffer = reportBuffers.removeValue(forKey: id) {
                IOHIDDeviceRegisterInputReportCallback(device, buffer.pointer, buffer.size, nil, nil)
                buffer.pointer.deallocate()
            }
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        openDevices.removeAll()
        pressedUsages.removeAll()
        pendingDevices.removeAll()
        retryTimer?.invalidate()
        retryTimer = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        }
        manager = nil
        if isRunning { log.add(.info, .device, "Stopped watching for remotes") }
        devices.removeAll()
        isRunning = false
    }

    // MARK: - Device lifecycle

    private func deviceMatched(_ device: IOHIDDevice, isRetry: Bool = false) {
        let id = Self.registryID(device)
        guard openDevices[id] == nil else { return }

        let usages = Self.inputUsages(device)
        let productID = Self.intProperty(device, kIOHIDProductIDKey) ?? 0
        guard SiriRemoteHID.knownModels[productID] != nil || SiriRemoteHID.looksLikeRemote(usages: usages) else {
            return
        }

        let address = Self.stringProperty(device, kIOHIDSerialNumberKey) ?? "unknown"
        let name = Self.stringProperty(device, kIOHIDProductKey) ?? "Siri Remote"

        var exclusive = wantExclusive
        var result = IOHIDDeviceOpen(device, IOOptionBits(exclusive ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess, exclusive, result != IOReturnCode.exclusiveAccess {
            log.add(.warning, .device, "Exclusive open failed (\(Self.describe(result))), retrying shared. macOS will also react to presses.")
            exclusive = false
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        let remote = RemoteDevice(
            id: id, productID: productID, name: name, address: address,
            modelName: SiriRemoteHID.modelName(productID: productID),
            openResult: result, exclusive: exclusive && result == kIOReturnSuccess, connectedAt: Date()
        )
        devices.removeAll { $0.id == id }
        devices.append(remote)

        guard result == kIOReturnSuccess else {
            pendingDevices[id] = device
            scheduleRetry()
            if !isRetry {
                log.add(.error, .device, "\(remote.modelName) connected but couldn't be opened: \(Self.describe(result)). Retrying every few seconds.")
                onDeviceConnected?(remote)
            }
            return
        }

        openDevices[id] = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, sender, value in
            guard let context else { return }
            let me = Unmanaged<HIDRemoteManager>.fromOpaque(context).takeUnretainedValue()
            let deviceID = sender.map { HIDRemoteManager.registryID(Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue()) } ?? 0
            MainActor.assumeIsolated { me.inputValue(value, deviceID: deviceID) }
        }, context)
        let size = max(Self.intProperty(device, kIOHIDMaxInputReportSizeKey) ?? 0, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        reportBuffers[id] = (buffer, size)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let me = Unmanaged<HIDRemoteManager>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated { me.rawReport(reportID: reportID, bytes: bytes) }
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        log.add(.success, .device, "\(remote.modelName) connected (\(address)), \(exclusive ? "exclusive" : "shared") access")
        onDeviceConnected?(remote)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let id = Self.registryID(device)
        releaseAllPressed(deviceID: id)
        pendingDevices[id] = nil
        openDevices[id] = nil
        reportBuffers.removeValue(forKey: id)?.pointer.deallocate()
        pressedUsages[id] = nil
        if let index = devices.firstIndex(where: { $0.id == id }) {
            let remote = devices.remove(at: index)
            lastDisconnect = Date()
            log.add(.info, .device, "\(remote.modelName) disconnected (asleep or out of range)")
            onDeviceDisconnected?(remote)
        }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryPending() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func retryPending() {
        let pending = pendingDevices
        pendingDevices.removeAll()
        for (_, device) in pending { deviceMatched(device, isRetry: true) }
        if pendingDevices.isEmpty {
            retryTimer?.invalidate()
            retryTimer = nil
        }
    }

    // MARK: - Input

    private func rawReport(reportID: UInt32, bytes: [UInt8]) {
        guard rawLogging else { return }
        log.add(.info, .device, "Raw buttons report id=0x\(String(reportID, radix: 16)): \(RawInputLogger.hex(bytes))")
    }

    private func inputValue(_ value: IOHIDValue, deviceID: UInt64) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        if rawLogging {
            log.add(.info, .device, "Raw value \(HIDUsage(page: page, usage: usage)) = \(IOHIDValueGetIntegerValue(value)) (\(IOHIDElementGetReportSize(element)) bit)")
        }
        // Skip padding bits and the collection itself.
        guard usage != 0, usage != UInt32.max, !(page == 0x0C && usage == 0x01) else { return }
        guard IOHIDElementGetReportSize(element) == 1 else { return }

        let hidUsage = HIDUsage(page: page, usage: usage)
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        var set = pressedUsages[deviceID] ?? []
        if pressed {
            guard set.insert(hidUsage).inserted else { return }
        } else {
            guard set.remove(hidUsage) != nil else { return }
        }
        pressedUsages[deviceID] = set
        onButton?(SiriRemoteHID.buttonUsages[hidUsage], hidUsage, pressed)
    }

    private func releaseAllPressed(deviceID: UInt64) {
        for usage in pressedUsages[deviceID] ?? [] {
            onButton?(SiriRemoteHID.buttonUsages[usage], usage, false)
        }
        pressedUsages[deviceID] = []
    }

    // MARK: - Helpers

    nonisolated static func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private static func inputUsages(_ device: IOHIDDevice) -> Set<HIDUsage> {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return []
        }
        return Set(elements.map { HIDUsage(page: IOHIDElementGetUsagePage($0), usage: IOHIDElementGetUsage($0)) })
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    static func describe(_ code: IOReturn) -> String {
        let hex = String(format: "0x%08X", UInt32(bitPattern: code))
        switch code {
        case kIOReturnSuccess: return "OK"
        case IOReturnCode.exclusiveAccess: return "another app has exclusive access (\(hex))"
        case IOReturnCode.notPermitted: return "not permitted, check Input Monitoring (\(hex))"
        case IOReturnCode.notPrivileged: return "not privileged (\(hex))"
        case IOReturnCode.noDevice: return "device went away (\(hex))"
        case IOReturnCode.busy: return "device busy (\(hex))"
        default: return hex
        }
    }
}

/// IOReturn values whose C macros don't import into Swift.
enum IOReturnCode {
    static let exclusiveAccess = IOReturn(bitPattern: 0xE000_02C5)
    static let notPermitted = IOReturn(bitPattern: 0xE000_02E2)
    static let notPrivileged = IOReturn(bitPattern: 0xE000_02C1)
    static let noDevice = IOReturn(bitPattern: 0xE000_02C0)
    static let busy = IOReturn(bitPattern: 0xE000_02D5)
}
