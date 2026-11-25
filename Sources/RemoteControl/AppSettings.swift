import Foundation
import RemoteCore

/// User preferences, persisted to UserDefaults on every change.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var mode: RemoteMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var mapping: ButtonMapping { didSet { saveMapping() } }
    /// Open the remote's button interface exclusively so macOS doesn't also act on presses.
    @Published var exclusiveAccess: Bool { didSet { defaults.set(exclusiveAccess, forKey: "exclusiveAccess") } }
    @Published var showModeHUD: Bool { didSet { defaults.set(showModeHUD, forKey: "showModeHUD") } }
    @Published var showScrollIndicator: Bool { didSet { defaults.set(showScrollIndicator, forKey: "showScrollIndicator") } }

    @Published var cursorSpeed: Double { didSet { defaults.set(cursorSpeed, forKey: "cursorSpeed") } }
    @Published var cursorAcceleration: Double { didSet { defaults.set(cursorAcceleration, forKey: "cursorAcceleration") } }
    @Published var scrollSpeed: Double { didSet { defaults.set(scrollSpeed, forKey: "scrollSpeed") } }
    @Published var reverseScroll: Bool { didSet { defaults.set(reverseScroll, forKey: "reverseScroll") } }
    @Published var holdToScrollDelay: Double { didSet { defaults.set(holdToScrollDelay, forKey: "holdToScrollDelay") } }

    @Published var batteryAlertsEnabled: Bool { didSet { defaults.set(batteryAlertsEnabled, forKey: "batteryAlertsEnabled") } }
    @Published var batteryThreshold: Int { didSet { defaults.set(batteryThreshold, forKey: "batteryThreshold") } }
    /// Set once a low-battery alert was sent; cleared when the level climbs back above the threshold.
    @Published var batteryAlertSent: Bool { didSet { defaults.set(batteryAlertSent, forKey: "batteryAlertSent") } }

    /// Drop the remote's Bluetooth link after it's been idle this long, to save its battery.
    @Published var sleepWhenIdle: Bool { didSet { defaults.set(sleepWhenIdle, forKey: "sleepWhenIdle") } }
    @Published var sleepIdleMinutes: Int { didSet { defaults.set(sleepIdleMinutes, forKey: "sleepIdleMinutes") } }
    /// Drop the link as soon as the Mac wakes between `daytimeStartHour` and `daytimeEndHour`.
    @Published var sleepOnDaytimeWake: Bool { didSet { defaults.set(sleepOnDaytimeWake, forKey: "sleepOnDaytimeWake") } }
    @Published var daytimeStartHour: Int { didSet { defaults.set(daytimeStartHour, forKey: "daytimeStartHour") } }
    @Published var daytimeEndHour: Int { didSet { defaults.set(daytimeEndHour, forKey: "daytimeEndHour") } }

    var sleepPolicy: SleepPolicy {
        SleepPolicy(
            idleEnabled: sleepWhenIdle, idleInterval: TimeInterval(sleepIdleMinutes * 60),
            dropOnDaytimeWake: sleepOnDaytimeWake, dayStartHour: daytimeStartHour, dayEndHour: daytimeEndHour
        )
    }

    /// Remotes seen on this Mac, keyed by Bluetooth address, so the Pairing tab can list sleeping ones.
    @Published var knownRemotes: [String: String] { didSet { defaults.set(knownRemotes, forKey: "knownRemotes") } }

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "mode": RemoteMode.remote.rawValue,
            "exclusiveAccess": true,
            "showModeHUD": true,
            "showScrollIndicator": true,
            "cursorSpeed": 1.0,
            "cursorAcceleration": 1.0,
            "scrollSpeed": 1.0,
            "reverseScroll": false,
            "holdToScrollDelay": 0.35,
            "batteryAlertsEnabled": true,
            "batteryThreshold": 20,
            "batteryAlertSent": false,
            "sleepWhenIdle": true,
            "sleepIdleMinutes": 60,
            "sleepOnDaytimeWake": true,
            "daytimeStartHour": 5,
            "daytimeEndHour": 18,
        ])
        enabled = defaults.bool(forKey: "enabled")
        mode = RemoteMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .remote
        exclusiveAccess = defaults.bool(forKey: "exclusiveAccess")
        showModeHUD = defaults.bool(forKey: "showModeHUD")
        showScrollIndicator = defaults.bool(forKey: "showScrollIndicator")
        cursorSpeed = defaults.double(forKey: "cursorSpeed")
        cursorAcceleration = defaults.double(forKey: "cursorAcceleration")
        scrollSpeed = defaults.double(forKey: "scrollSpeed")
        reverseScroll = defaults.bool(forKey: "reverseScroll")
        holdToScrollDelay = defaults.double(forKey: "holdToScrollDelay")
        batteryAlertsEnabled = defaults.bool(forKey: "batteryAlertsEnabled")
        batteryThreshold = defaults.integer(forKey: "batteryThreshold")
        batteryAlertSent = defaults.bool(forKey: "batteryAlertSent")
        sleepWhenIdle = defaults.bool(forKey: "sleepWhenIdle")
        sleepIdleMinutes = max(defaults.integer(forKey: "sleepIdleMinutes"), 5)
        sleepOnDaytimeWake = defaults.bool(forKey: "sleepOnDaytimeWake")
        daytimeStartHour = defaults.integer(forKey: "daytimeStartHour")
        daytimeEndHour = defaults.integer(forKey: "daytimeEndHour")
        knownRemotes = defaults.dictionary(forKey: "knownRemotes") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "mapping"),
           var saved = try? JSONDecoder().decode(ButtonMapping.self, from: data) {
            saved.migrate(from: defaults.integer(forKey: "mappingVersion"))
            mapping = saved
        } else {
            mapping = .defaults
        }
        defaults.set(ButtonMapping.currentVersion, forKey: "mappingVersion")
        saveMapping()
    }

    private func saveMapping() {
        if let data = try? JSONEncoder().encode(mapping) { defaults.set(data, forKey: "mapping") }
    }

    func resetMapping(for mode: RemoteMode) {
        switch mode {
        case .remote: mapping.remote = ButtonMapping.defaultRemote
        case .trackpad: mapping.trackpad = ButtonMapping.defaultTrackpad
        }
    }
}
