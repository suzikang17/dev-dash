import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for posting local notifications.
/// All methods are safe to call even if authorization was denied — the center
/// silently drops requests it can't deliver.
enum Notifier {
    /// Request .alert + .sound authorization once.  No-ops if already determined.
    static func requestAuthIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Post an immediate local notification. Safe to call without prior auth check.
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        let id = UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
