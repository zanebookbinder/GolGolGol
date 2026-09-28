import Foundation
import GoalKit
import UserNotifications

/// Heads-up notifications posted on the iPhone (and shown on the Watch when the phone is locked).
/// Each kind is posted at most once a day.
enum GoalAlerts {
    static func post(id: String, title: String, body: String, day: DayKey = .today()) {
        let key = "alert-\(id)"
        guard AppGroup.defaults.string(forKey: key) != day.rawValue else { return }
        AppGroup.defaults.set(day.rawValue, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id)-\(day.rawValue)", content: content, trigger: nil))
    }
}
