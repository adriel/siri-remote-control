import CoreBluetooth
import Foundation

/// Drops the remote's Bluetooth LE link, and brings it back when a button is pressed.
///
/// macOS keeps a bonded remote connected for as long as it's in range, so its radio never goes fully idle.
/// There's no public API to disconnect a system-owned LE HID device. What works on macOS 27: join the
/// system's connection with CoreBluetooth, then cancel it with two private options:
///
/// - `kCBCancelConnectOptionForce` tears the link down even though the HID driver, not this app, uses it.
///   On its own macOS reconnects within a couple of seconds, though.
/// - `kCBCancelConnectOptionDoNotAutoConnectBuiltInServices` stops that reconnect, and also stops macOS
///   reconnecting by itself later.
///
/// Once disconnected, the remote advertises in two ways (measured on a Siri Remote 2nd gen):
///
/// - Slow heartbeat: one burst every 3 seconds, without the HID service UUID. It's still connectable, so a
///   plain connect request would bring it straight back.
/// - "Connect to me": a burst every 0.3 seconds that includes the HID service UUID (0x1812). It sends these
///   for about 20 seconds after the link drops, and again after a button press.
///
/// So while the remote sleeps, the app scans for the HID service only. Once the burst that follows the drop
/// has died down, the next HID advertisement from the remote means a button was pressed: the app connects,
/// and the system's HID driver attaches again.
///
/// The private pieces are looked up at runtime, so on a macOS without them this reports `.unsupported`.
@MainActor
final class RemoteLink: NSObject {
    enum Outcome: Equatable {
        case requested
        case notFound
        case unsupported
        case bluetoothUnavailable(String)
        case failed(String)

        var description: String {
            switch self {
            case .requested: "requested"
            case .notFound: "CoreBluetooth doesn't know the remote"
            case .unsupported: "this macOS doesn't have the private CoreBluetooth calls"
            case let .bluetoothUnavailable(why): why
            case let .failed(why): why
            }
        }
    }

    /// Called when a button press was seen and the app is reconnecting the remote.
    var onButtonPressSeen: (() -> Void)?
    /// Called when Bluetooth comes (back) on, since a scan doesn't survive it going off.
    var onPoweredOn: (() -> Void)?

    private var central: CBCentralManager?
    private var waitingForCentral: [(CBCentralManager?) -> Void] = []
    private var pendingConnects: [UUID: [(Bool) -> Void]] = [:]
    private let defaults = UserDefaults.standard

    /// What `watchForButtonPress` is looking for.
    private struct Watch {
        var identifier: UUID?
        var addressBytes: Data
        /// HID advertisements before this are the burst that follows the drop, not a button press.
        var armedAfter: Date
        var lastAdvert: Date?
        var connecting = false
    }
    private var watch: Watch?
    private var armTimer: Timer?

    nonisolated private static let hidService = CBUUID(string: "1812")
    /// The burst after the drop has ended once no HID advertisement has been seen for this long.
    private static let quietBeforeArming: TimeInterval = 3
    /// If no advertisement shows up at all after the drop, arm after this long (the burst lasts about 20 s).
    private static let noBurstSeenDelay: TimeInterval = 25
    /// Arm anyway after this long, in case the burst never seemed to end.
    private static let maxBurst: TimeInterval = 45

    var isWatching: Bool { watch != nil }

    /// Drops the link. Whether it worked shows up as the remote's HID device going away.
    func disconnect(address: String, name: String) async -> Outcome {
        guard let force = Self.privateKey("CBCancelPeripheralConnectionOptionForce"),
              let noAutoConnect = Self.privateKey("CBCancelPeripheralConnectionOptionDoNotAutoConnectBuiltInServices") else {
            return .unsupported
        }
        let selector = NSSelectorFromString("cancelPeripheralConnection:options:")
        guard CBCentralManager.instancesRespond(to: selector) else { return .unsupported }
        let (central, failure) = await poweredOnCentral()
        guard let central else { return failure }
        guard let peripheral = findPeripheral(central, address: address, name: name) else { return .notFound }
        remember(peripheral, address: address)

        // Cancelling only affects connections this app is part of, so join the system's connection first.
        // The link is already up, so this completes straight away.
        if peripheral.state != .connected {
            guard await connect(peripheral, on: central, timeout: 4) else {
                return .failed("couldn't join the remote's connection")
            }
        }
        typealias CancelWithOptions = @convention(c) (AnyObject, Selector, CBPeripheral, NSDictionary) -> Void
        let cancel = unsafeBitCast(central.method(for: selector), to: CancelWithOptions.self)
        cancel(central, selector, peripheral, [force: true, noAutoConnect: true] as NSDictionary)
        return .requested
    }

    /// Scans for the remote's "connect to me" advertisement and reconnects it when a button is pressed.
    /// - Parameter justDropped: true right after `disconnect`, so the burst that follows isn't taken for a press.
    func watchForButtonPress(address: String, name: String, justDropped: Bool) async -> Outcome {
        let (central, failure) = await poweredOnCentral()
        guard let central else { return failure }
        let now = Date()
        let known = findPeripheral(central, address: address, name: name)
        if let known { remember(known, address: address) }
        watch = Watch(
            identifier: known?.identifier,
            addressBytes: Self.addressBytes(address),
            armedAfter: justDropped ? now.addingTimeInterval(Self.maxBurst) : now
        )
        if justDropped {
            // Arm as soon as the burst dies down, checked once a second.
            armTimer?.invalidate()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, var watch = self.watch else { timer.invalidate(); return }
                    // Before the first advertisement shows up (the scan takes a moment), wait a fixed time instead.
                    let ready = watch.lastAdvert.map { Date().timeIntervalSince($0) >= Self.quietBeforeArming }
                        ?? (Date().timeIntervalSince(now) >= Self.noBurstSeenDelay)
                    if ready {
                        watch.armedAfter = min(watch.armedAfter, Date())
                        self.watch = watch
                        timer.invalidate()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            armTimer = timer
        }
        central.scanForPeripherals(withServices: [Self.hidService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        return .requested
    }

    /// Stops scanning, e.g. because the remote is back.
    func stopWatching() {
        guard watch != nil else { return }
        watch = nil
        armTimer?.invalidate()
        armTimer = nil
        central?.stopScan()
    }

    private func advertisement(from peripheral: CBPeripheral, data: [String: Any]) {
        guard var watch, let central else { return }
        let manufacturer = data[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        let isOurRemote = peripheral.identifier == watch.identifier
            || (!watch.addressBytes.isEmpty && manufacturer.range(of: watch.addressBytes) != nil)
        guard isOurRemote, !watch.connecting else { return }
        let now = Date()
        watch.lastAdvert = now
        guard now >= watch.armedAfter else {
            self.watch = watch
            return
        }
        watch.connecting = true
        self.watch = watch
        onButtonPressSeen?()
        Task { @MainActor in
            let connected = await connect(peripheral, on: central, timeout: 10)
            guard var current = self.watch else { return }
            if connected {
                stopWatching()
            } else {
                // Missed it (the remote went back to sleep mid-connect). Keep watching.
                current.connecting = false
                self.watch = current
            }
        }
    }

    private static func addressBytes(_ address: String) -> Data {
        let hex = Array(address.lowercased().filter(\.isHexDigit))
        guard hex.count == 12 else { return Data() }
        return Data(stride(from: 0, to: 12, by: 2).compactMap { UInt8(String(hex[$0..<$0 + 2]), radix: 16) })
    }

    // MARK: Connecting

    private func connect(_ peripheral: CBPeripheral, on central: CBCentralManager, timeout: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = peripheral.identifier
            var done = false
            let finish: (Bool) -> Void = { connected in
                guard !done else { return }
                done = true
                continuation.resume(returning: connected)
            }
            pendingConnects[id, default: []].append(finish)
            central.connect(peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private func finishConnect(_ id: UUID, connected: Bool) {
        for waiter in pendingConnects.removeValue(forKey: id) ?? [] { waiter(connected) }
    }

    // MARK: Finding the remote

    private func findPeripheral(_ central: CBCentralManager, address: String, name: String) -> CBPeripheral? {
        let target = Self.normalize(address)
        if let stored = rememberedIDs[target].flatMap(UUID.init(uuidString:)),
           let peripheral = central.retrievePeripherals(withIdentifiers: [stored]).first {
            return peripheral
        }
        var connected = central.retrieveConnectedPeripherals(withServices: [Self.hidService])
        let allowAll = NSSelectorFromString("retrieveConnectedPeripheralsWithServices:allowAll:")
        if central.responds(to: allowAll) {
            // The public call hides peripherals other processes connected, which includes the system's HID link.
            typealias RetrieveAll = @convention(c) (AnyObject, Selector, NSArray, ObjCBool) -> NSArray?
            let retrieve = unsafeBitCast(central.method(for: allowAll), to: RetrieveAll.self)
            if let all = retrieve(central, allowAll, [Self.hidService] as NSArray, true) as? [CBPeripheral] {
                connected += all.filter { peripheral in !connected.contains { $0.identifier == peripheral.identifier } }
            }
        }
        if let match = connected.first(where: { Self.normalize(Self.bdAddress($0) ?? "") == target }) { return match }
        if let match = connected.first(where: { $0.name == name }) { return match }
        let byAddress = NSSelectorFromString("retrievePeripheralWithAddress:")
        if central.responds(to: byAddress),
           let peripheral = central.perform(byAddress, with: address)?.takeUnretainedValue() as? CBPeripheral {
            return peripheral
        }
        return nil
    }

    /// CoreBluetooth identifiers by Bluetooth address, so a sleeping remote can be found again after a relaunch.
    private var rememberedIDs: [String: String] {
        get { defaults.dictionary(forKey: "remotePeripheralIDs") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "remotePeripheralIDs") }
    }

    private func remember(_ peripheral: CBPeripheral, address: String) {
        rememberedIDs[Self.normalize(address)] = peripheral.identifier.uuidString
    }

    private static func bdAddress(_ peripheral: CBPeripheral) -> String? {
        let selector = NSSelectorFromString("BDAddress")
        guard peripheral.responds(to: selector), let value = peripheral.perform(selector)?.takeUnretainedValue() else { return nil }
        if let string = value as? String { return string }
        if let data = value as? Data { return data.map { String(format: "%02x", $0) }.joined() }
        return String(describing: value)
    }

    private static func normalize(_ address: String) -> String {
        address.lowercased().filter(\.isHexDigit)
    }

    /// A private CoreBluetooth string constant, looked up by symbol name.
    private static func privateKey(_ symbol: String) -> String? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", RTLD_NOLOAD | RTLD_NOW),
              let pointer = dlsym(handle, symbol) else { return nil }
        return pointer.assumingMemoryBound(to: NSString.self).pointee as String
    }

    // MARK: Central

    private func poweredOnCentral() async -> (CBCentralManager?, Outcome) {
        if central?.state == .poweredOn { return (central, .requested) }
        if let central, central.state != .unknown, central.state != .resetting {
            return (nil, .bluetoothUnavailable(Self.describe(central.state)))
        }
        let ready = await withCheckedContinuation { continuation in
            waitingForCentral.append { continuation.resume(returning: $0) }
            if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishWaiting() }
        }
        return (ready, ready == nil ? .bluetoothUnavailable(Self.describe(central?.state ?? .unknown)) : .requested)
    }

    private func finishWaiting() {
        let waiters = waitingForCentral
        waitingForCentral.removeAll()
        let ready = central?.state == .poweredOn ? central : nil
        for waiter in waiters { waiter(ready) }
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access isn't allowed (System Settings → Privacy & Security → Bluetooth)"
        case .unsupported: "Bluetooth LE isn't supported"
        case .resetting: "Bluetooth is resetting"
        default: "Bluetooth isn't ready"
        }
    }
}

extension RemoteLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            guard state != .unknown, state != .resetting else { return }
            finishWaiting()
            // Bluetooth was switched off or reset: the scan is gone, so the owner has to start it again.
            if state != .poweredOn { stopWatching() }
            if state == .poweredOn { onPoweredOn?() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        nonisolated(unsafe) let data = advertisementData
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated { advertisement(from: peripheral, data: data) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { finishConnect(id, connected: true) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { finishConnect(id, connected: false) }
    }
}
