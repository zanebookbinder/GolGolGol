import Foundation
import GoalKit
import UserNotifications
import WatchKit

/// Announces a new cheer on the Watch (a notification and a haptic tap), at most once per cheer per day.
enum Cheers {
    private static let key = "cheered"
    private static let rank: [Celebration: Int] = [.goooool: 1, .hatTrick: 2]

    @MainActor static func announceIfNew(_ celebration: Celebration?, day: DayKey = .today()) {
        guard let celebration else { return }
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        let (storedDay, storedRank) = parse(stored)
        guard storedDay != day.rawValue || storedRank < rank[celebration, default: 0] else { return }
        UserDefaults.standard.set("\(day.rawValue)|\(rank[celebration, default: 0])", forKey: key)

        WKInterfaceDevice.current().play(.success)
        let content = UNMutableNotificationContent()
        content.title = celebration.title
        content.body = celebration.message
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cheer-\(day.rawValue)", content: content, trigger: nil))
    }

    private static func parse(_ stored: String) -> (String, Int) {
        let parts = stored.split(separator: "|")
        return (parts.first.map(String.init) ?? "", parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    }
}
