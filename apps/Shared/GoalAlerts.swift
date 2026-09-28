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

    /// After a snapshot: warns when pickups are within 10 of the limit. Pickups have no live data, so
    /// this can only happen when a snapshot runs.
    static func checkPickups(_ pickups: Int, goal: Goal?, day: DayKey) {
        guard let goal, goal.active, day == .today() else { return }
        let left = Int(goal.target) - pickups
        guard left > 0, left <= 10 else { return }
        post(id: "pickups-warning", title: "\(left) pickups left today",
             body: "You're at \(pickups) of your \(Int(goal.target))-pickup limit.", day: day)
    }
}
