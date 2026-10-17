import AppKit
import ApplicationServices
import CoreBluetooth
import IOKit.hid
import UserNotifications

enum Permissions {
    enum Status: Equatable {
        case granted, denied, notDetermined

        var label: String {
            switch self {
            case .granted: "Granted"
            case .denied: "Not granted"
            case .notDetermined: "Not requested yet"
            }
        }
    }

    enum Pane: String {
        case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case inputMonitoring = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case bluetoothPrivacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        case bluetooth = "x-apple.systempreferences:com.apple.BluetoothSettings"
        case notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    }

    /// Needed to post keystrokes, clicks, cursor moves, scrolls and media keys.
    static var accessibility: Status { AXIsProcessTrusted() ? .granted : .denied }

    /// Needed to read the remote's HID reports.
    static var inputMonitoring: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .notDetermined
        }
    }

    static var bluetooth: Status {
        switch CBCentralManager.authorization {
        case .allowedAlways: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func notifications() async -> Status {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func requestNotifications() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: pane.rawValue) { NSWorkspace.shared.open(url) }
    }
}
