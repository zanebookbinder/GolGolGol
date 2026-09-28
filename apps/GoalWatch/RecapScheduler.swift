import Foundation
import UserNotifications

/// The nightly recap: a repeating local notification with Yes/No overeating actions, so the
/// question can be answered without opening the app. The text stays generic because watchOS
/// doesn't guarantee background time right before it fires.
enum RecapScheduler {
    static let category = "RECAP"
    static let didNotOvereat = "OVEREAT_NO"
    static let overate = "OVEREAT_YES"
    private static let identifier = "nightly-recap"

    static func registerCategories() {
        let recap = UNNotificationCategory(
            identifier: category,
            actions: [
                UNNotificationAction(identifier: didNotOvereat, title: "Didn't over-eat"),
                UNNotificationAction(identifier: overate, title: "Did over-eat"),
            ],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([recap])
    }

    static func schedule(minutes: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Your day"
        content.body = "Tap to review. Did you over-eat today?"
        content.categoryIdentifier = category
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: minutes / 60, minute: minutes % 60), repeats: true)
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        } catch {
            print("Recap scheduling failed: \(error)")
        }
    }

    /// Immediate alert, e.g. "Screen Time access was lost" from the iPhone.
    static func postAlert(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Golazo"
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
