import BackgroundTasks
import FamilyControls
import GoalKit
import SwiftUI
import UserNotifications

@main
struct GoalCompanionApp: App {
    nonisolated static let refreshTaskId = "com.zanebookbinder.goaltracker.refresh"

    @UIApplicationDelegateAdaptor private var appDelegate: PhoneAppDelegate
    @State private var model = AppModel.shared
    @State private var snapshotDay: SnapshotDay?
    @State private var snapshotOutcome: SnapshotOutcome?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DeviceLink.shared.activate()
        let model = AppModel.shared
        model.onChange.append { data in
            DeviceLink.shared.push(data, session: AppModel.shared.session)
            ScreenTimeMonitor.sync(with: data)
        }
        model.onScreenTimeReadings = { DeviceLink.shared.send($0) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Stays presented while switching days (no dismiss/re-present animation for a
                // screenshot to catch), and closes as soon as the numbers are submitted.
                .fullScreenCover(isPresented: Binding(get: { snapshotDay != nil }, set: { if !$0 { snapshotDay = nil } })) {
                    if let day = snapshotDay {
                        SnapshotScreen(day: day).id(day)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .snapshotSubmitted)) { _ in
                    snapshotDay = nil
                }
                .onOpenURL(perform: handle)
                .alert(snapshotOutcome?.succeeded == true ? "Snapshot saved" : "Snapshot didn't work",
                       isPresented: Binding(get: { snapshotOutcome != nil }, set: { if !$0 { snapshotOutcome = nil } }),
                       presenting: snapshotOutcome) { _ in
                    Button("OK") {}
                } message: { outcome in
                    Text(outcome.message)
                }
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            Task {
                await model.start()
                await model.refresh()
                await ScreenTimeMonitor.checkHealth()
                #if DEBUG
                ScreenTimeMonitor.writeDebugSnapshot()
                #endif
                // For the screen time heads-up; asks once.
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await SnapshotReminders.schedule()
                Self.scheduleRefresh()
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskId)) {
            await AppModel.shared.refresh()
            await ScreenTimeMonitor.checkHealth()
            Self.scheduleRefresh()
        }
    }

    private func handle(_ url: URL) {
        switch SnapshotLink(url: url) {
        case .show(let day):
            snapshotDay = day
        case .run(let day):
            SnapshotRunner.run(day)
        case .finished:
            snapshotDay = nil
            Task {
                await model.refresh()
                // Only speak up if the reading was rejected; success is shown on Today.
                if let outcome = SnapshotRunner.latestOutcome(), !outcome.succeeded { snapshotOutcome = outcome }
            }
        case .failed(let message):
            snapshotDay = nil
            let hint = message.localizedCaseInsensitiveContains("find") || message.localizedCaseInsensitiveContains("exist")
                ? " Install the Snapshot shortcuts from Settings → Screen Time first." : ""
            snapshotOutcome = SnapshotRunner.latestOutcome() ?? SnapshotOutcome(succeeded: false, message: message + hint)
        case nil:
            break
        }
    }

    /// Retries uploads the monitor extension couldn't finish and keeps the Watch's data fresh.
    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = .now.addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Keeps DeviceActivity monitoring in step with the screen time goal and watches for lost access.
enum ScreenTimeMonitor {
    private static let alertedKey = "screenTimeAlertDay"

    #if DEBUG
    /// The Screen Time log and monitoring state, copied into the app's own container where
    /// `devicectl` can read it (the App Group can't be).
    @MainActor static func writeDebugSnapshot() {
        let state: [String: Any] = [
            "authorization": "\(AuthorizationCenter.shared.authorizationStatus)",
            "monitoringActive": Monitoring.isActive,
            "hasSelection": Monitoring.hasSelection,
            "targetMinutes": MonitoringSettings.targetMinutes,
            "registeredLadder": MonitoringSettings.registeredLadder,
            "log": EventLog.read().suffix(60).map { "\($0.date.formatted(date: .omitted, time: .standard)) \($0.kind.rawValue) \($0.message)" },
        ]
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) else { return }
        try? data.write(to: caches.appending(path: "screentime-debug.json"))
    }
    #endif

    /// Called on every data change: passes the owner and target to the extension and re-registers
    /// the threshold ladder when the target changes.
    static func sync(with data: StoreData) {
        MonitoringSettings.ownerId = data.ownerId
        syncEvening(with: data)
        guard let goal = data.goals.first(where: { $0.type == .screenTime }), goal.active else { return }
        let target = Int(goal.target)
        MonitoringSettings.targetMinutes = target
        guard MonitoringSettings.needsRegistering else { return }
        if AuthorizationCenter.shared.authorizationStatus == .approved {
            try? Monitoring.start()
        }
    }

    /// Runs the 9pm–3am schedule while the phone-before-bed goal is on.
    static func syncEvening(with data: StoreData) {
        let wanted = data.goals.contains { $0.type == .phoneBeforeBed && $0.active }
        guard AuthorizationCenter.shared.authorizationStatus == .approved, Monitoring.hasSelection else { return }
        if wanted, !Monitoring.isEveningActive || MonitoringSettings.registeredEveningLadder != Bedtime.ladder {
            do {
                try Monitoring.startEvening()
            } catch {
                EventLog.append(.error, "Couldn't start evening monitoring: \(error.localizedDescription)")
            }
        } else if !wanted, Monitoring.isEveningActive {
            Monitoring.stopEvening()
        }
    }

    /// Authorization sometimes goes missing (reported on iOS 26). Re-register if we can; otherwise
    /// warn on the Watch, once a day.
    @MainActor static func checkHealth() async {
        guard AppModel.shared.data.preferences.onboarded,
              AppModel.shared.data.goals.contains(where: { $0.type == .screenTime && $0.active }) else { return }
        // Right after launch the status reads "not determined" until Family Controls loads it, so give
        // it a few seconds before concluding access is gone.
        for _ in 0..<10 where AuthorizationCenter.shared.authorizationStatus != .approved {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if AuthorizationCenter.shared.authorizationStatus == .approved {
            if !Monitoring.isActive {
                do {
                    try Monitoring.start()
                    EventLog.append(.monitoring, "Monitoring restarted")
                } catch {
                    EventLog.append(.error, "Couldn't restart monitoring: \(error.localizedDescription)")
                }
            }
            syncEvening(with: AppModel.shared.data)
            if Monitoring.isActive && Monitoring.hasSelection {
                let marker = Monitoring.monitoringMarker(ownerId: AppModel.shared.data.ownerId)
                Task { await AppModel.shared.record([marker]) }
            }
            return
        }
        let today = DayKey.today().rawValue
        guard AppGroup.defaults.string(forKey: alertedKey) != today else { return }
        AppGroup.defaults.set(today, forKey: alertedKey)
        EventLog.append(.error, "Screen Time access was lost (status: \(AuthorizationCenter.shared.authorizationStatus))")
        DeviceLink.shared.sendAlert("Screen Time access was lost. Open Golazo on your iPhone to turn it back on.")
    }
}
