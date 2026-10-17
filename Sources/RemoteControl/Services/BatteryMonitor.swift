import Foundation
import IOKit.ps
import RemoteCore

/// Reads the remote's battery level from the accessory power sources macOS publishes
/// (the same data `pmset -g accps` shows).
@MainActor
final class BatteryMonitor: ObservableObject {
    struct Reading: Equatable {
        let level: Int
        let isCharging: Bool
        let name: String
        let productID: Int
        let date: Date
    }

    @Published private(set) var reading: Reading?
    var onReading: ((Reading) -> Void)?

    private let log = DiagnosticsLog.shared
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?

    private typealias CopyPowerSourcesByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    /// `IOPSCopyPowerSourcesByType` is exported by IOKit but not in the public headers. Type 4 includes accessories.
    private static let copyPowerSourcesByType: CopyPowerSourcesByType? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopyPowerSourcesByType.self)
    }()

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        // Accessory sources don't always trigger the notification, so poll as well.
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        guard let latest = Self.readRemoteBattery() else { return }
        let changed = latest.level != reading?.level
        reading = latest
        if changed { log.add(.info, .battery, "Remote battery \(latest.level)%") }
        onReading?(latest)
    }

    private static func readRemoteBattery() -> Reading? {
        guard let copy = copyPowerSourcesByType, let info = copy(4)?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as NSArray? else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any] else { continue }
            let vendor = d["Vendor ID"] as? Int ?? 0
            let product = d["Product ID"] as? Int ?? 0
            guard vendor == SiriRemoteHID.vendorID, SiriRemoteHID.knownModels[product] != nil else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return Reading(
                level: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                isCharging: d[kIOPSIsChargingKey] as? Bool ?? false,
                name: d[kIOPSNameKey] as? String ?? "Siri Remote",
                productID: product,
                date: Date()
            )
        }
        return nil
    }
}
