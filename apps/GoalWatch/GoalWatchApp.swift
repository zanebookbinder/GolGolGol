import GoalKit
import SwiftUI
import UserNotifications
import WatchKit
import WidgetKit

@main
struct GoalWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @State private var path = NavigationPath()
    @State private var page: WatchPage = .today

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                // Swipe between pages: Today › History › Partner › Settings.
                TabView(selection: $page) {
                    TodayView().tag(WatchPage.today)
                    HistoryView().tag(WatchPage.history)
                    PartnerListView(isVisible: page == .partner).tag(WatchPage.partner)
                    WatchSettingsView().tag(WatchPage.settings)
                }
                .tabViewStyle(.page)
                // The page name sits top-left, on the clock's row, leaving the rest of the screen for content.
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text(page.title)
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                            .fixedSize()
                    }
                }
                .navigationDestination(for: WatchRoute.self) { $0.destination }
            }
            .environment(AppModel.shared)
            .onOpenURL(perform: open)
            #if DEBUG
            // For checking screens in the simulator, which can't open URLs on watchOS:
            // SIMCTL_CHILD_GOAL_OPEN_URL=goaltracker://history xcrun simctl launch …
            .task {
                guard let url = WatchAppDelegate.debugOpenURL else { return }
                await AppModel.shared.start()
                open(url)
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .openToday)) { _ in
                path = NavigationPath()
                page = .today
            }
        }
    }
}

extension GoalWatchApp {
    /// goaltracker://today (also the recap, whose questions live on Today), goaltracker://history,
    /// goaltracker://goal?type=steps&day=yesterday
    private func open(_ url: URL) {
        let model = AppModel.shared
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "today", "recap":
            path = NavigationPath()
            page = .today
        case "history":
            path = NavigationPath()
            page = .history
        case "goal":
            let day = items.first { $0.name == "day" }?.value == "yesterday" ? model.yesterday : model.today
            if let type = items.first(where: { $0.name == "type" })?.value.flatMap(GoalType.init(rawValue:)),
               let goal = model.data.goals.first(where: { $0.type == type }) {
                path.append(WatchRoute.goalDay(goal, day))
            }
        default:
            break
        }
    }
}

enum WatchPage: Hashable {
    case settings, partner, today, history

    var title: String {
        switch self {
        case .settings: "Settings"
        case .partner: "Partner"
        case .today: "Today"
        case .history: "History"
        }
    }
}

enum WatchRoute: Hashable {
    case goalDay(Goal, DayKey)

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .goalDay(let goal, let day): GoalDayView(goal: goal, day: day)
        }
    }
}

extension Notification.Name {
    static let openToday = Notification.Name("openToday")
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    private let refreshInterval: TimeInterval = 30 * 60

    #if DEBUG
    static let debugOpenURL = ProcessInfo.processInfo.environment["GOAL_OPEN_URL"].flatMap(URL.init(string:))
    #else
    static let debugOpenURL: URL? = nil
    #endif

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        RecapScheduler.registerCategories()
        DeviceLink.shared.onAlert = { message in RecapScheduler.postAlert(message) }
        DeviceLink.shared.activate()

        Task { @MainActor in
            let model = AppModel.shared
            var lastRecapMinutes: Int?
            model.onChange.append { data in
                WidgetCenter.shared.reloadAllTimelines()
                DeviceLink.shared.push(data, session: nil)
                ProgressReminders.update(data)
                if data.preferences.recapMinutes != lastRecapMinutes {
                    lastRecapMinutes = data.preferences.recapMinutes
                    Task { await RecapScheduler.schedule(minutes: data.preferences.recapMinutes) }
                }
            }
            await model.start()
            // Screen checks in the simulator skip permission prompts so they don't cover the screen.
            if Self.debugOpenURL == nil {
                try? await HealthCollector.shared.requestAuthorization()
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
            HealthCollector.shared.observe { await AppModel.shared.refresh() }
            await model.refresh()
        }
        scheduleRefresh()
    }

    func applicationDidBecomeActive() {
        Task { @MainActor in await AppModel.shared.refresh() }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                Task { @MainActor in
                    await AppModel.shared.refresh()
                    self.scheduleRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: .now.addingTimeInterval(refreshInterval), userInfo: nil) { error in
            if let error { print("scheduleBackgroundRefresh: \(error)") }
        }
    }

    // MARK: Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let day = DayKey(response.notification.date)
        switch response.actionIdentifier {
        case RecapScheduler.didNotOvereat:
            await AppModel.shared.answer(.overeating, yes: false, day: day)
        case RecapScheduler.overate:
            await AppModel.shared.answer(.overeating, yes: true, day: day)
        case UNNotificationDefaultActionIdentifier where response.notification.request.content.categoryIdentifier == RecapScheduler.category:
            // The recap's questions are at the top of Today.
            await MainActor.run { NotificationCenter.default.post(name: .openToday, object: nil) }
        default:
            break
        }
    }
}
