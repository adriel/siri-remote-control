import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, buttons, battery, pairing, diagnostics
    var id: String { rawValue }
}

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Tall enough for the Diagnostics tab without scrolling; the other tabs scroll inside it.
    static let defaultSize = NSSize(width: 780, height: 800)
    static let minimumSize = NSSize(width: 700, height: 680)

    private var window: NSWindow?
    private let controller: RemoteController
    private let selection = SettingsSelection()

    init(controller: RemoteController) {
        self.controller = controller
    }

    func show(_ tab: SettingsTab) {
        selection.tab = tab
        if window == nil {
            let root = Self.rootView(controller: controller, selection: selection)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Remote Control"
            window.contentView = NSHostingView(rootView: root)
            window.contentMinSize = Self.minimumSize
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // Remember the size the user picks, but never come back smaller than the minimum.
            window.setFrameAutosaveName("RemoteControlSettings")
            if window.contentLayoutRect.height < Self.minimumSize.height || window.contentLayoutRect.width < Self.minimumSize.width {
                window.setContentSize(Self.defaultSize)
                window.center()
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func rootView(controller: RemoteController, selection: SettingsSelection) -> some View {
        SettingsRootView()
            .environmentObject(selection)
            .environmentObject(controller)
            .environmentObject(controller.settings)
            .environmentObject(controller.hid)
            .environmentObject(controller.touch)
            .environmentObject(controller.battery)
            .environmentObject(controller.batteryHistory)
            .environmentObject(controller.pairing)
            .environmentObject(controller.log)
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ButtonsTab()
                .tabItem { Label("Buttons", systemImage: "appletvremote.gen4") }
                .tag(SettingsTab.buttons)
            BatteryTab()
                .tabItem { Label("Battery", systemImage: "battery.75percent") }
                .tag(SettingsTab.battery)
            PairingTab()
                .tabItem { Label("Pairing", systemImage: "link") }
                .tag(SettingsTab.pairing)
            DiagnosticsTab()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(SettingsTab.diagnostics)
        }
        .padding(.top, 4)
        .frame(minWidth: SettingsWindowController.minimumSize.width, minHeight: SettingsWindowController.minimumSize.height)
    }
}
