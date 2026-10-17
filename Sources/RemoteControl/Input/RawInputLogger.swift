import Foundation
import IOKit
import IOKit.hid
import RemoteCore

/// Diagnostics aid: opens the remote's other HID interfaces (touch, microphone, sensors, vendor) in shared mode
/// and logs their raw reports. The buttons interface is logged by HIDRemoteManager, which already holds it.
@MainActor
final class RawInputLogger {
    private let log = DiagnosticsLog.shared
    private var manager: IOHIDManager?
    private var devices: [UInt64: (device: IOHIDDevice, name: String, buffer: UnsafeMutablePointer<UInt8>, size: Int)] = [:]
    private var lastPayload: [UInt64: [UInt8]] = [:]

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: SiriRemoteHID.vendorID,
            kIOHIDTransportKey: SiriRemoteHID.transport,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<RawInputLogger>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.attach(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<RawInputLogger>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.detach(HIDRemoteManager.registryID(device), gone: true) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
        log.add(.info, .device, "Raw input logging on")
    }

    private func stop() {
        guard let manager else { return }
        for id in devices.keys { detach(id, gone: false) }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        self.manager = nil
        log.add(.info, .device, "Raw input logging off")
    }

    private func attach(_ device: IOHIDDevice) {
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        guard SiriRemoteHID.knownModels[productID] != nil, !(page == 0x0C && usage == 0x01) else { return }
        let id = HIDRemoteManager.registryID(device)
        guard devices[id] == nil else { return }
        let name = SiriRemoteHID.interfaceName(page: page, usage: usage)
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            log.add(.warning, .device, "Raw logging couldn't open \(name): \(HIDRemoteManager.describe(result))")
            return
        }
        let size = max(IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        devices[id] = (device, name, buffer, size)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, _, sender, _, reportID, report, length in
            guard let context, let sender else { return }
            let me = Unmanaged<RawInputLogger>.fromOpaque(context).takeUnretainedValue()
            let id = HIDRemoteManager.registryID(Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue())
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated { me.report(id: id, reportID: reportID, bytes: bytes) }
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        log.add(.info, .device, "Raw logging attached to \(name) interface")
    }

    private func detach(_ id: UInt64, gone: Bool) {
        guard let entry = devices.removeValue(forKey: id) else { return }
        if !gone {
            IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, entry.size, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(entry.device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        entry.buffer.deallocate()
        lastPayload[id] = nil
    }

    private func report(id: UInt64, reportID: UInt32, bytes: [UInt8]) {
        guard let name = devices[id]?.name, lastPayload[id] != bytes else { return }
        lastPayload[id] = bytes
        log.add(.info, .device, "Raw \(name) id=0x\(String(reportID, radix: 16)) len=\(bytes.count): \(Self.hex(bytes, limit: 40))")
    }

    static func hex(_ bytes: [UInt8], limit: Int = 64) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return bytes.count > limit ? shown + " …" : shown
    }
}
