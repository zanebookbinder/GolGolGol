import SwiftUI
import UIKit
import UserNotifications

/// Runs the Snapshot shortcut from inside the app. The app can't screenshot Apple's report view
/// itself, so it asks Shortcuts to run the shortcut via x-callback-url; Shortcuts opens the Snapshot
/// screen, screenshots it, submits the numbers, then returns to `goaltracker://snapshot-done`.
enum SnapshotRunner {
    static func shortcutName(for day: SnapshotDay) -> String {
        day == .today ? "Snapshot" : "Snapshot (Yesterday)"
    }

    static func runURL(for day: SnapshotDay) -> URL {
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        components.queryItems = [
            .init(name: "name", value: shortcutName(for: day)),
            .init(name: "x-success", value: "goaltracker://snapshot-done"),
            .init(name: "x-error", value: "goaltracker://snapshot-failed"),
            .init(name: "x-cancel", value: "goaltracker://snapshot-failed?errorMessage=Cancelled"),
        ]
        return components.url!
    }

    @MainActor static func run(_ day: SnapshotDay) {
        UIApplication.shared.open(runURL(for: day))
    }

    /// The signed shortcut files bundled with the app, for one-tap install.
    static func bundledShortcut(for day: SnapshotDay) -> URL? {
        Bundle.main.url(forResource: shortcutName(for: day), withExtension: "shortcut")
    }

    /// The most recent snapshot outcome in the last few minutes, to show when Shortcuts returns.
    static func latestOutcome() -> SnapshotOutcome? {
        guard let event = EventLog.read().last(where: { $0.kind == .snapshot || $0.kind == .snapshotRejected }),
              event.date.timeIntervalSinceNow > -5 * 60 else { return nil }
        return SnapshotOutcome(succeeded: event.kind == .snapshot, message: event.message)
    }
}

struct SnapshotOutcome: Identifiable {
    let id = UUID()
    var succeeded: Bool
    var message: String
}

/// goaltracker:// links the app handles for snapshots.
enum SnapshotLink {
    /// Show the Snapshot screen (the shortcut's first step).
    case show(SnapshotDay)
    /// Run the shortcut (from a notification or widget).
    case run(SnapshotDay)
    /// Shortcuts finished the shortcut.
    case finished
    case failed(String)

    init?(url: URL) {
        guard url.scheme == "goaltracker" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let day: SnapshotDay = items.first { $0.name == "day" }?.value == "yesterday" ? .yesterday : .today
        switch url.host {
        case "snapshot": self = .show(day)
        case "take-snapshot": self = .run(day)
        case "snapshot-done": self = .finished
        case "snapshot-failed": self = .failed(items.first { $0.name == "errorMessage" }?.value ?? "The shortcut didn't finish.")
        default: return nil
        }
    }
}

/// Evening and morning notifications that run the snapshot when tapped.
enum SnapshotReminders {
    struct Settings: Codable, Equatable {
        var eveningOn = true
        /// Minutes after midnight. Default 9pm, before the 9:30 recap so it has exact numbers.
        var eveningMinutes = 21 * 60
        var morningOn = true
        /// Finalizes yesterday. Default 8am.
        var morningMinutes = 8 * 60
    }

    static let dayKey = "snapshotDay"
    private static let settingsKey = "snapshotReminders"
    private static let ids = ["snapshot-evening", "snapshot-morning"]

    static var settings: Settings {
        get {
            AppGroup.defaults.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        }
        set {
            AppGroup.defaults.set(try? JSONEncoder().encode(newValue), forKey: settingsKey)
        }
    }

    static func schedule() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        let settings = settings
        guard settings.eveningOn || settings.morningOn else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

        func add(_ id: String, minutes: Int, title: String, body: String, day: SnapshotDay) async {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = [dayKey: day.rawValue]
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: minutes / 60, minute: minutes % 60), repeats: true)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        if settings.eveningOn {
            await add(ids[0], minutes: settings.eveningMinutes, title: "Record today's screen time",
                      body: "Tap to take a snapshot of your exact screen time and pickups.", day: .today)
        }
        if settings.morningOn {
            await add(ids[1], minutes: settings.morningMinutes, title: "Finalize yesterday",
                      body: "Tap to record yesterday's final screen time and pickups.", day: .yesterday)
        }
    }
}

/// Tapping a snapshot reminder runs the shortcut.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo[SnapshotReminders.dayKey] as? String,
              let day = SnapshotDay(rawValue: raw) else { return }
        // Give the app a moment to come to the foreground before handing off to Shortcuts.
        try? await Task.sleep(for: .milliseconds(600))
        await MainActor.run { SnapshotRunner.run(day) }
    }
}

/// Take-snapshot buttons, shown on the Today screen.
struct SnapshotButtons: View {
    var body: some View {
        Section {
            Button {
                SnapshotRunner.run(.today)
            } label: {
                Label("Take snapshot now", systemImage: "camera.viewfinder")
            }
            Button {
                SnapshotRunner.run(.yesterday)
            } label: {
                Label("Finalize yesterday", systemImage: "sunrise")
            }
        } header: {
            Text("Exact screen time")
        } footer: {
            Text("Runs the Snapshot shortcut: Shortcuts opens for a few seconds, then brings you back here.")
        }
    }
}

/// One-tap install of the bundled shortcuts through the share sheet (choose Shortcuts).
struct ShortcutInstallButtons: View {
    var body: some View {
        ForEach([SnapshotDay.today, .yesterday]) { day in
            if let url = SnapshotRunner.bundledShortcut(for: day) {
                ShareLink(item: url) {
                    Label("Install \"\(SnapshotRunner.shortcutName(for: day))\" shortcut", systemImage: "square.and.arrow.down")
                }
            }
        }
    }
}

/// Reminder toggles and times, shown in Settings.
struct SnapshotReminderSettings: View {
    @State private var settings = SnapshotReminders.settings

    var body: some View {
        Toggle("Evening reminder", isOn: $settings.eveningOn)
            .onChange(of: settings) {
                SnapshotReminders.settings = settings
                Task { await SnapshotReminders.schedule() }
            }
        if settings.eveningOn {
            DatePicker("Time", selection: time(\.eveningMinutes), displayedComponents: .hourAndMinute)
        }
        Toggle("Morning reminder (finalize yesterday)", isOn: $settings.morningOn)
        if settings.morningOn {
            DatePicker("Time", selection: time(\.morningMinutes), displayedComponents: .hourAndMinute)
        }
    }

    private func time(_ keyPath: WritableKeyPath<SnapshotReminders.Settings, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .minute, value: settings[keyPath: keyPath], to: Calendar.current.startOfDay(for: .now))! },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings[keyPath: keyPath] = c.hour! * 60 + c.minute!
            }
        )
    }
}
