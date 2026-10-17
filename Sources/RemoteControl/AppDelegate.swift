import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: RemoteController!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Notifier.shared.configure()

        controller = RemoteController()
        settingsWindow = SettingsWindowController(controller: controller)
        statusItem = StatusItemController(controller: controller) { [weak self] tab in
            self?.settingsWindow.show(tab)
        }
        NotificationCenter.default.addObserver(forName: .openSettingsTab, object: nil, queue: .main) { [weak self] note in
            guard let tab = note.object as? SettingsTab else { return }
            MainActor.assumeIsolated { self?.settingsWindow.show(tab) }
        }

        controller.start()
        Task { _ = await Permissions.requestNotifications() }

        // First launch, or permissions missing: show Diagnostics so the user can see what to grant.
        if !UserDefaults.standard.bool(forKey: "launchedBefore") || Permissions.accessibility != .granted {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            settingsWindow.show(.diagnostics)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show(.general)
        return true
    }

    /// Accessory apps have no visible menu bar, but the main menu still supplies ⌘W, ⌘C, ⌘Q and friends.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Remote Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
