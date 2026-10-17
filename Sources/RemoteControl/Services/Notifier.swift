import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func lowBattery(level: Int, threshold: Int) {
        post(
            id: "low-battery",
            title: "Siri Remote battery low",
            body: "The battery is at \(level)%, at or below your \(threshold)% alert level. Charge it soon."
        )
    }

    func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task { @MainActor in
                DiagnosticsLog.shared.add(.error, .battery, "Notification failed: \(error.localizedDescription)")
            }
        }
    }

    // Show banners even though the app is technically always "active" as a menu bar app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
