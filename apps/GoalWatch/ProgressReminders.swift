import Foundation
import GoalKit
import UserNotifications

/// The 6pm nudge: if steps or the workout aren't completed by then, the Watch says what's left.
/// Local notifications can't check conditions when they fire, so this is re-planned whenever the
/// Watch's data changes: scheduled for today at 6pm with the current numbers, or removed once both
/// are completed. After 6pm it plans tomorrow's.
enum ProgressReminders {
    static let hour = 18
    private static let id = "progress-6pm"

    static func update(_ data: StoreData, now: Date = .now) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let today = DayKey(now)
        let sixToday = Calendar.current.date(byAdding: .hour, value: hour, to: today.start())!
        let day = now < sixToday ? today : today.adding(days: 1)
        let fireDate = Calendar.current.date(byAdding: .hour, value: hour, to: day.start())!

        var remaining: [String] = []
        for type in [GoalType.steps, .workout] {
            guard let goal = data.activeGoals.first(where: { $0.type == type }), goal.applies(on: day) else { continue }
            // For tomorrow nothing is known yet, so assume it's still to do.
            let summary = day == today ? data.summary(goalId: goal.id, day: day) : nil
            guard summary?.status != .hit else { continue }
            switch type {
            case .steps:
                let left = Int(goal.target - (summary?.value ?? 0))
                remaining.append(day == today ? "\(left.formatted()) steps to go" : "steps")
            default:
                remaining.append("workout not done yet")
            }
        }
        guard !remaining.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Still to do today"
        content.body = day == today ? remaining.joined(separator: " · ").capitalizedFirst : "Check your steps and workout."
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
