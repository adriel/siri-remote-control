import AppKit
import Foundation
import RemoteCore

/// Puts the remote to sleep by dropping its Bluetooth link when it isn't being used, and logs each sleep so
/// the Battery tab can show whether it saves charge.
///
/// - After `idleInterval` with no button press or touch, the link is dropped. The check uses the wall
///   clock, so time the Mac spent asleep counts too.
/// - When the Mac wakes during the day (5:00–18:00 by default), the link is dropped right away, or as soon
///   as the remote reconnects after the wake.
/// - A button press wakes the remote: it sends a "connect to me" advertisement, the app connects, and the
///   HID driver attaches again. See `RemoteLink`.
@MainActor
final class RemoteSleeper: ObservableObject {
    enum State: Equatable {
        /// Connected and in use.
        case connected
        /// Not connected, but not because of us (out of range, Mac just woke, Bluetooth off).
        case disconnected
        case dropping
        case asleep(since: Date)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var sleepLog: SleepLog
    /// Why the last attempt to drop the link failed, if it did.
    @Published private(set) var lastError: String?
    /// The last button press or touch. Reconnects don't count, so a Mac wake can't hide that the remote is idle.
    @Published private(set) var lastActivity = Date()

    private let settings: AppSettings
    private let hid: HIDRemoteManager
    private let battery: BatteryMonitor
    private let log = DiagnosticsLog.shared
    private let link = RemoteLink()
    private let fileURL: URL?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Set when the Mac woke during the day but the remote wasn't connected yet: drop it once it is.
    private var dropAfterWakeUntil: Date?
    private var removalWaiter: ((Bool) -> Void)?
    /// After a reconnect that wasn't a wake from sleep, don't drop for idleness until this time. The press that
    /// brought the remote back may not have reached the app.
    private var idleGraceUntil: Date?
    private var running = false

    /// How long to wait after a daytime Mac wake for the remote to reconnect so it can be dropped.
    private static let wakeDropWindow: TimeInterval = 180
    private static let reconnectGrace: TimeInterval = 600

    init(settings: AppSettings, hid: HIDRemoteManager, battery: BatteryMonitor, fileURL: URL? = RemoteSleeper.defaultURL, sleepLog: SleepLog? = nil) {
        self.settings = settings
        self.hid = hid
        self.battery = battery
        self.fileURL = fileURL
        if let sleepLog {
            self.sleepLog = sleepLog
        } else if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(SleepLog.self, from: data) {
            self.sleepLog = saved
        } else {
            self.sleepLog = SleepLog()
        }
        if let current = self.sleepLog.current { state = .asleep(since: current.start) }
    }

    var policy: SleepPolicy { settings.sleepPolicy }

    var isAsleep: Bool {
        if case .asleep = state { return true }
        return false
    }

    func start() {
        guard !running else { return }
        running = true
        link.onButtonPressSeen = { [weak self] in
            self?.log.add(.info, .sleep, "Saw a button press on the sleeping remote, reconnecting")
        }
        link.onPoweredOn = { [weak self] in
            guard let self, self.state != .connected, self.state != .dropping else { return }
            self.waitForButtonPress(justDropped: false)
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.macDidWake() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.log.add(.info, .sleep, "Mac is going to sleep") }
        })

        if case let .asleep(since) = state {
            log.add(.info, .sleep, "The remote has been asleep since \(Self.time(since)). Press any button to wake it.")
        }
        // A remote left asleep by an earlier run won't reconnect on its own, so watch for a button press.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.hid.devices.isEmpty else { return }
            self.waitForButtonPress(justDropped: false)
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if isAsleep {
            log.add(.warning, .sleep, "Quitting while the remote is asleep. It reconnects the next time Remote Control runs, or connect it from Bluetooth settings.")
        }
        running = false
    }

    // MARK: Events from the controller

    /// A button press or touch.
    func noteActivity() {
        lastActivity = Date()
        dropAfterWakeUntil = nil
        idleGraceUntil = nil
    }

    func remoteConnected(_ remote: HIDRemoteManager.RemoteDevice) {
        let now = Date()
        defer { persistRemoteName(remote.name) }
        link.stopWatching()
        if case let .asleep(since) = state {
            sleepLog.end(at: now, level: nil)
            save()
            state = .connected
            lastActivity = now
            lastError = nil
            log.add(.success, .sleep, "The remote woke after \(Self.duration(now.timeIntervalSince(since))) asleep")
            return
        }
        guard state != .dropping else { return }
        state = .connected
        if let until = dropAfterWakeUntil, now < until, lastActivity < now {
            // Give the touch surface and battery a moment to come up, and the user a chance to press something.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.state == .connected, self.lastActivity < now else { return }
                self.sleepNow(reason: "the Mac woke during the day")
            }
        } else {
            idleGraceUntil = now.addingTimeInterval(Self.reconnectGrace)
        }
    }

    func remoteDisconnected(_ remote: HIDRemoteManager.RemoteDevice) {
        if state == .dropping {
            removalWaiter?(true)
            return
        }
        guard !isAsleep, hid.devices.isEmpty else { return }
        state = .disconnected
        // macOS normally reconnects on its own after this, but not if an earlier drop turned that off.
        waitForButtonPress(justDropped: false)
    }

    func noteBattery(_ reading: BatteryMonitor.Reading) {
        guard sleepLog.noteReading(level: reading.level, at: reading.date) else { return }
        save()
        if let period = sleepLog.periods.last, let used = period.used {
            log.add(.info, .sleep, "Battery \(reading.level)% after waking: used \(used)% in \(Self.duration(period.duration(now: reading.date))) asleep")
        }
    }

    // MARK: Dropping the link

    /// Drops the link now. The remote stays asleep until a button is pressed.
    func sleepNow(reason: String) {
        guard state == .connected, let remote = hid.devices.first, remote.address != "unknown" else { return }
        state = .dropping
        battery.refresh()
        let level = battery.reading.flatMap { Date().timeIntervalSince($0.date) < 3600 ? $0.level : nil }
        Task { @MainActor in
            let outcome = await link.disconnect(address: remote.address, name: remote.name)
            guard outcome == .requested else {
                failed(outcome.description)
                return
            }
            guard await waitForRemoval(timeout: 6) else {
                failed("macOS kept the link up")
                return
            }
            let now = Date()
            sleepLog.begin(at: now, reason: reason, level: level)
            save()
            state = .asleep(since: now)
            dropAfterWakeUntil = nil
            lastError = nil
            let battery = level.map { ", battery \($0)%" } ?? ""
            log.add(.success, .sleep, "Disconnected the remote to save battery (\(reason)\(battery)). Press any button to wake it.")
            waitForButtonPress(justDropped: true)
        }
    }

    private func waitForRemoval(timeout: TimeInterval) async -> Bool {
        if hid.devices.isEmpty { return true }
        return await withCheckedContinuation { continuation in
            var done = false
            let finish: (Bool) -> Void = { [weak self] gone in
                guard !done else { return }
                done = true
                self?.removalWaiter = nil
                continuation.resume(returning: gone)
            }
            removalWaiter = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private func failed(_ why: String) {
        state = hid.devices.isEmpty ? .disconnected : .connected
        // Try again after another idle interval rather than every minute.
        idleGraceUntil = Date().addingTimeInterval(policy.idleInterval)
        lastError = why
        log.add(.warning, .sleep, "Couldn't disconnect the remote: \(why)")
    }

    private func waitForButtonPress(justDropped: Bool) {
        guard let address = remoteAddress else { return }
        guard justDropped || !link.isWatching else { return }
        Task { @MainActor in
            let outcome = await link.watchForButtonPress(address: address, name: remoteName, justDropped: justDropped)
            if outcome != .requested {
                log.add(.warning, .sleep, "Can't listen for the remote to wake: \(outcome.description). If a button press doesn't bring it back, connect it from Bluetooth settings.")
            }
        }
    }

    // MARK: Timers

    private func checkIdle() {
        let now = Date()
        if let grace = idleGraceUntil, now < grace { return }
        guard state == .connected, policy.isIdle(lastActivity: lastActivity, now: now) else { return }
        sleepNow(reason: "no button presses for \(Self.duration(policy.idleInterval))")
    }

    private func macDidWake() {
        let now = Date()
        guard policy.shouldDropOnWake(at: now, lastActivity: lastActivity) else {
            log.add(.info, .sleep, "Mac woke at \(Self.time(now))")
            if isAsleep {
                // Scanning may not survive the Mac's sleep, so start it again.
                link.stopWatching()
                waitForButtonPress(justDropped: false)
            }
            checkIdle()
            return
        }
        switch state {
        case .connected:
            log.add(.info, .sleep, "Mac woke at \(Self.time(now)), during the day: disconnecting the remote")
            // If this attempt fails because Bluetooth is still coming up, the reconnect that follows retries.
            dropAfterWakeUntil = now.addingTimeInterval(Self.wakeDropWindow)
            sleepNow(reason: "the Mac woke during the day")
        case .disconnected:
            log.add(.info, .sleep, "Mac woke at \(Self.time(now)), during the day: the remote will be disconnected when it reconnects")
            dropAfterWakeUntil = now.addingTimeInterval(Self.wakeDropWindow)
        case .dropping, .asleep:
            log.add(.info, .sleep, "Mac woke at \(Self.time(now)); the remote is already asleep")
            // Scanning may not survive the Mac's sleep, so start it again.
            if isAsleep {
                link.stopWatching()
                waitForButtonPress(justDropped: false)
            }
        }
    }

    // MARK: Helpers

    private var remoteAddress: String? {
        if let address = hid.devices.first?.address, address != "unknown" { return address }
        return settings.knownRemotes.keys.sorted().first
    }

    /// The HID product name (the remote's serial), which CoreBluetooth uses as the peripheral name.
    private var remoteName: String {
        hid.devices.first?.name ?? UserDefaults.standard.string(forKey: "remoteName") ?? "Siri Remote"
    }

    private func persistRemoteName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "remoteName")
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(sleepLog).write(to: fileURL, options: .atomic)
        } catch {
            log.add(.error, .sleep, "Couldn't save the sleep log: \(error.localizedDescription)")
        }
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    nonisolated static let defaultURL: URL? = BatteryHistoryStore.defaultURL?
        .deletingLastPathComponent().appendingPathComponent("remote-sleep.json")
}
