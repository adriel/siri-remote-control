import AppKit
import Combine
import RemoteCore

/// The menu bar icon. Left-click opens the menu; right-click (or ⌃-click) toggles the app on/off.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: RemoteController
    private let settings: AppSettings
    private let openSettings: (SettingsTab) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(controller: RemoteController, openSettings: @escaping (SettingsTab) -> Void) {
        self.controller = controller
        self.settings = controller.settings
        self.openSettings = openSettings
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        Publishers.CombineLatest3(settings.$enabled, settings.$mode, controller.hid.$devices)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let connected = !controller.hid.devices.isEmpty
        button.image = MenuBarIcon.image(trackpad: settings.enabled && settings.mode == .trackpad)
        button.appearsDisabled = !settings.enabled || !connected
        var tip = "Remote Control: " + (settings.enabled ? settings.mode.displayName : "Off")
        tip += connected ? "" : " (remote not connected)"
        tip += "\nRight-click to turn \(settings.enabled ? "off" : "on")"
        button.toolTip = tip
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            controller.toggleEnabled()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let remote = controller.hid.devices.first
        var status = remote.map { "\($0.modelName): Connected" } ?? "Siri Remote: Not connected"
        if let level = controller.battery.reading?.level { status += " · \(level)%" }
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = settings.enabled ? .on : .off
        menu.addItem(enabled)

        for mode in RemoteMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settings.mode == mode ? .on : .off
            item.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil)
            item.isEnabled = settings.enabled
            menu.addItem(item)
        }
        let hint = NSMenuItem(title: "Siri button switches modes · Right-click icon toggles on/off", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(openGeneral), key: ","))
        menu.addItem(item("Button Mapping…", #selector(openButtons)))
        menu.addItem(item("Battery…", #selector(openBattery)))
        menu.addItem(item("Pair / Unpair Remote…", #selector(openPairing)))
        menu.addItem(item("Diagnostics…", #selector(openDiagnostics)))
        menu.addItem(.separator())
        menu.addItem(item("Restart Remote Control", #selector(restart)))
        menu.addItem(item("Quit Remote Control", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { controller.toggleEnabled() }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = RemoteMode(rawValue: raw) else { return }
        controller.setMode(mode)
    }

    @objc private func openGeneral() { openSettings(.general) }
    @objc private func openButtons() { openSettings(.buttons) }
    @objc private func openBattery() { openSettings(.battery) }
    @objc private func openPairing() { openSettings(.pairing) }
    @objc private func openDiagnostics() { openSettings(.diagnostics) }
    @objc private func restart() { AppRelauncher.relaunch() }
    @objc private func quit() { NSApp.terminate(nil) }
}
