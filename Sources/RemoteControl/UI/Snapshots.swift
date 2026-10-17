import AppKit
import RemoteCore
import SwiftUI

/// Development aid: `RemoteControl --snapshot <dir>` renders each settings tab and the overlays to PNGs
/// without starting input handling or asking for permissions.
@MainActor
enum Snapshots {
    static func run(outputDirectory: String) {
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = RemoteController(batteryHistory: BatteryHistoryStore(fileURL: nil, history: sampleHistory(now: Date())))
        let selection = SettingsSelection()

        let log = DiagnosticsLog.shared
        log.mirrorsToSystemLog = false
        log.add(.info, .system, "Permissions: Accessibility Granted, Input Monitoring Granted")
        log.add(.success, .device, "Siri Remote (2nd gen or later) connected (58:0a:d4:a6:4d:ee), exclusive access")
        log.add(.success, .touch, "Touch surface attached")
        for i in 0..<6 {
            log.add(.success, .button, "Back ↓ [0x01:0x86] in Remote mode → Key ←: sent ← to Safari (\(i))")
            log.add(.info, .touch, "Finger down at (0.48, 0.22)")
        }
        log.add(.warning, .button, "Unrecognised HID usage 0x0C:0x109 pressed, no button mapped")

        for tab in SettingsTab.allCases {
            selection.tab = tab
            render(SettingsWindowController.rootView(controller: controller, selection: selection),
                   size: SettingsWindowController.defaultSize, to: dir.appendingPathComponent("tab-\(tab.rawValue).png"))
            if tab == .diagnostics {
                render(SettingsWindowController.rootView(controller: controller, selection: selection),
                       size: SettingsWindowController.minimumSize, to: dir.appendingPathComponent("tab-diagnostics-min.png"))
            }
        }
        // Menu bar icons, enlarged, on light and dark bars.
        render(HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 28) {
                    ForEach([false, true], id: \.self) { trackpad in
                        Image(nsImage: MenuBarIcon.image(trackpad: trackpad))
                            .renderingMode(.template).resizable().interpolation(.high)
                            .frame(width: 90, height: 90)
                            .foregroundStyle(dark ? Color.white : Color.black)
                    }
                    Image(nsImage: MenuBarIcon.image(trackpad: false)).renderingMode(.template)
                        .foregroundStyle(dark ? Color.white : Color.black)
                }
                .padding(24)
                .background(dark ? Color(white: 0.18) : Color(white: 0.93))
            }
        }, size: NSSize(width: 640, height: 140), to: dir.appendingPathComponent("menubar-icons.png"))

        // Buttons tab with the pointer over the TV row.
        render(ButtonsTab(initialHover: .tv).environmentObject(controller).environmentObject(controller.settings).padding(.top, 8),
               size: SettingsWindowController.defaultSize, to: dir.appendingPathComponent("buttons-hover-tv.png"))
        render(ButtonsTab(initialHover: .left).environmentObject(controller).environmentObject(controller.settings).padding(.top, 8),
               size: SettingsWindowController.defaultSize, to: dir.appendingPathComponent("buttons-hover-left.png"))

        // The Battery tab with generated history, in both ranges (restoring the user's range choice after).
        let defaults = UserDefaults.standard
        let savedRange = defaults.object(forKey: "batteryHistoryRange")
        selection.tab = .battery
        for range in HistoryRange.allCases {
            defaults.set(range.rawValue, forKey: "batteryHistoryRange")
            render(SettingsWindowController.rootView(controller: controller, selection: selection),
                   size: NSSize(width: 760, height: range == .month ? 7400 : 1500), to: dir.appendingPathComponent("battery-history-\(range.rawValue)d.png"))
        }
        if let savedRange { defaults.set(savedRange, forKey: "batteryHistoryRange") } else { defaults.removeObject(forKey: "batteryHistoryRange") }

        render(HStack(spacing: 24) {
            RemoteDiagramView(pressed: [], touch: nil).frame(width: 110, height: 330)
            RemoteDiagramView(pressed: [.up, .back, .volumeUp, .siri], touch: CGPoint(x: 0.7, y: 0.75)).frame(width: 110, height: 330)
            RemoteDiagramView(pressed: [.select, .tv, .playPause, .mute, .volumeDown, .power], touch: nil).frame(width: 110, height: 330)
        }.padding(20).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 450, height: 380), to: dir.appendingPathComponent("diagram.png"))
        print("Snapshots written to \(dir.path)")
    }

    /// A month of plausible readings: slow drain, heavier use in the evenings, a charge, and a few days asleep.
    private static func sampleHistory(now: Date) -> BatteryHistory {
        var history = BatteryHistory()
        let start = now.addingTimeInterval(-31 * 86_400)
        var level = 62.0
        var time = start
        while time < now {
            let day = Int(time.timeIntervalSince(start) / 86_400)
            let hour = Calendar.current.component(.hour, from: time)
            if ![5, 6, 7, 19].contains(day) {
                level -= (18...23).contains(hour) ? 0.15 : 0.02
                if day == 17, hour == 9 { level = 100 }
                history.record(level: Int(level.rounded()), at: time)
            }
            time += 1800
        }
        return history
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
