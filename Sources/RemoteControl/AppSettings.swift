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
