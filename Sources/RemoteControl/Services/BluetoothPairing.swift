import AppKit
import CoreBluetooth
import IOBluetooth

/// Pairing and unpairing of Siri Remotes.
///
/// macOS has no public API for pairing Bluetooth LE HID devices. Pairing here connects to a remote in
/// pairing mode with CoreBluetooth and reads a protected characteristic, which makes macOS bond with it.
/// System Settings → Bluetooth is the fallback. Unpairing uses IOBluetooth's `-[IOBluetoothDevice remove]`,
/// the same private call `blueutil --unpair` makes.
@MainActor
final class BluetoothPairing: NSObject, ObservableObject {
    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
        let peripheral: CBPeripheral
    }

    enum State: Equatable {
        case idle
        case scanning
        case connecting(String)
        case waitingForSystem(String)
        case paired(String)
        case failed(String)
    }

    enum UnpairResult {
        case removed, notFound, unsupported
    }

    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var state: State = .idle

    private let log = DiagnosticsLog.shared
    private var central: CBCentralManager?
    private var scanWhenReady = false
    private var connecting: CBPeripheral?
    private var timeout: DispatchWorkItem?

    nonisolated private static let hidService = CBUUID(string: "1812")

    // MARK: Scanning

    func startScan() {
        candidates.removeAll()
        state = .scanning
        if let central, central.state == .poweredOn {
            beginScan(central)
        } else {
            scanWhenReady = true
            if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        }
    }

    func stopScan() {
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    private func beginScan(_ central: CBCentralManager) {
        scanWhenReady = false
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log.add(.info, .pairing, "Scanning for remotes in pairing mode")
    }

    // MARK: Pairing

    func pair(_ candidate: Candidate) {
        guard let central else { return }
        central.stopScan()
        connecting = candidate.peripheral
        candidate.peripheral.delegate = self
        state = .connecting(candidate.name)
        log.add(.info, .pairing, "Connecting to \(candidate.name)")
        central.connect(candidate.peripheral)
        scheduleTimeout(seconds: 30)
    }

    func cancel() {
        timeout?.cancel()
        if let connecting { central?.cancelPeripheralConnection(connecting) }
        connecting = nil
        central?.stopScan()
        state = .idle
    }

    /// Called when a remote's HID interface appears. That's the sign macOS finished bonding.
    func remoteDidConnect(name: String) {
        switch state {
        case .connecting, .waitingForSystem, .scanning:
            timeout?.cancel()
            central?.stopScan()
            connecting = nil
            state = .paired(name)
            log.add(.success, .pairing, "\(name) is paired and connected")
        default:
            break
        }
    }

    private func scheduleTimeout(seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .paired = self.state { return }
            self.cancel()
            self.state = .failed("macOS didn't finish pairing. Pair from Bluetooth Settings instead: the remote shows under Nearby Devices while it's in pairing mode.")
            self.log.add(.warning, .pairing, "In-app pairing timed out")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Unpairing

    static func unpair(address: String) -> UnpairResult {
        let target = normalize(address)
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let device = paired.first(where: { normalize($0.addressString ?? "") == target }) ?? IOBluetoothDevice(addressString: address) else {
            return .notFound
        }
        let remove = NSSelectorFromString("remove")
        guard device.responds(to: remove) else { return .unsupported }
        device.perform(remove)
        return .removed
    }

    /// Whether macOS still lists the address as paired. nil when we can't tell without prompting for Bluetooth access.
    static func isPaired(address: String) -> Bool? {
        guard Permissions.bluetooth == .granted else { return nil }
        let target = normalize(address)
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.contains { normalize($0.addressString ?? "") == target }
    }

    private static func normalize(_ address: String) -> String {
        address.lowercased().filter(\.isHexDigit)
    }

    static func openBluetoothSettings() {
        Permissions.open(.bluetooth)
    }
}

extension BluetoothPairing: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if scanWhenReady { beginScan(central) }
            case .unauthorized:
                state = .failed("Bluetooth access was denied. Allow it in System Settings → Privacy & Security → Bluetooth.")
            case .poweredOff:
                state = .failed("Bluetooth is off.")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let isApple = manufacturer.map { $0.count >= 2 && $0[$0.startIndex] == 0x4C && $0[$0.startIndex + 1] == 0x00 } ?? false
        let looksLikeRemote = name?.localizedCaseInsensitiveContains("remote") ?? false
        guard looksLikeRemote || (isApple && services.contains(Self.hidService)) else { return }
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            if let index = candidates.firstIndex(where: { $0.id == id }) {
                candidates[index].rssi = rssi
            } else {
                candidates.append(Candidate(id: id, name: name ?? "Siri Remote", rssi: rssi, peripheral: peripheral))
                log.add(.info, .pairing, "Found \(name ?? "a remote") nearby (RSSI \(rssi))")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            state = .waitingForSystem("Connected. Waiting for macOS to finish pairing. Approve any prompt that appears.")
            log.add(.info, .pairing, "Connected, starting bonding")
        }
        peripheral.discoverServices(nil)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        MainActor.assumeIsolated {
            timeout?.cancel()
            state = .failed("Couldn't connect: \(message)")
            log.add(.error, .pairing, "Connect failed: \(message)")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Reading an encrypted characteristic makes macOS start bonding.
        for characteristic in service.characteristics ?? [] where characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        }
    }
}
