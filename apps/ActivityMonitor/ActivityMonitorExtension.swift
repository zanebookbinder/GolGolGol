import DeviceActivity
import Foundation
import GoalKit

/// Receives DeviceActivity callbacks. Kept small: extensions have tight memory limits and a short run
/// window. Each reading goes to the App Group inbox first (the app drains it into the store), then
/// is uploaded directly so the Watch sees it without the companion app opening.
final class ActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // Rebuild the ladder in case the goal changed since the schedule was registered.
        if MonitoringSettings.needsRegistering {
            do {
                try Monitoring.start()
            } catch {
                EventLog.append(.error, "Couldn't rebuild thresholds: \(error.localizedDescription)")
            }
        }
        guard Monitoring.hasSelection else {
            EventLog.append(.error, "Day started, but no apps or categories are selected, so screen time can't be measured")
            return
        }
        deliver(Monitoring.monitoringMarker(ownerId: MonitoringSettings.ownerId))
        EventLog.append(.monitoring, "Day started")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let minutes = Monitoring.minutes(from: event) else { return }
        deliver(Monitoring.crossing(minutes: minutes, ownerId: MonitoringSettings.ownerId))
        if minutes == MonitoringSettings.targetMinutes - ThresholdLadder.warningMinutes {
            GoalAlerts.post(id: "screen-time-warning", title: "30 minutes of screen time left",
                            body: "You're at \(GoalFormat.duration(minutes: Double(minutes))) of your \(GoalFormat.duration(minutes: Double(MonitoringSettings.targetMinutes))) limit today.")
        }
        EventLog.append(.threshold, "Screen time passed \(GoalFormat.duration(minutes: Double(minutes)))")
    }

    private func deliver(_ metric: Metric) {
        AppGroup.inbox.append([metric])
        guard metric.ownerId != LocalStore.localOwnerId, let config = BackendConfig.load() else { return }
        let api = GoalAPI(client: GraphQLClient(url: config.graphQLURL, auth: CognitoAuth(config: config, store: AppGroup.keychain)))
        let done = DispatchSemaphore(value: 0)
        Task {
            try? await api.put(metric)
            done.signal()
        }
        // Stay alive long enough for the upload; if it fails, the app retries from the inbox.
        _ = done.wait(timeout: .now() + 10)
    }
}
