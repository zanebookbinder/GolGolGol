import DeviceActivity
import Foundation
import GoalKit

/// Receives DeviceActivity callbacks. iOS gives this extension a few MB of memory and a short run
/// window and kills it if it goes over, so it does the minimum: records the reading in the App Group
/// inbox (the app drains it into the store and uploads it on its next launch or background refresh)
/// and posts the "30 minutes left" heads-up. No networking or login here.
final class ActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if activity == Monitoring.eveningActivity {
            AppGroup.inbox.append([Bedtime.monitoringMarker(ownerId: MonitoringSettings.ownerId)])
            EventLog.append(.monitoring, "Evening monitoring running (9pm–3am)")
            return
        }
        guard Monitoring.hasSelection else {
            EventLog.append(.error, "Day started, but no apps or categories are selected, so screen time can't be measured")
            return
        }
        AppGroup.inbox.append([Monitoring.monitoringMarker(ownerId: MonitoringSettings.ownerId)])
        // iOS calls this at midnight and whenever the app (re)registers the schedule mid-day; either way
        // the thresholds count usage since midnight.
        EventLog.append(.monitoring, "Monitoring running for today (counting from midnight)")
        // Rebuild the ladder in case the goal changed since the schedule was registered.
        if MonitoringSettings.needsRegistering {
            do {
                try Monitoring.start()
            } catch {
                EventLog.append(.error, "Couldn't rebuild thresholds: \(error.localizedDescription)")
            }
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let minutes = Monitoring.minutes(from: event) else { return }
        if activity == Monitoring.eveningActivity {
            AppGroup.inbox.append([Bedtime.crossing(threshold: minutes, ownerId: MonitoringSettings.ownerId)])
            EventLog.append(.threshold, "Evening phone use passed \(minutes)m")
            return
        }
        AppGroup.inbox.append([Monitoring.crossing(minutes: minutes, ownerId: MonitoringSettings.ownerId)])
        EventLog.append(.threshold, "Screen time passed \(GoalFormat.duration(minutes: Double(minutes)))")

        let target = MonitoringSettings.targetMinutes
        if minutes == target - ThresholdLadder.warningMinutes {
            GoalAlerts.post(id: "screen-time-warning", title: "30 minutes of screen time left",
                            body: "You're at \(GoalFormat.duration(minutes: Double(minutes))) of your \(GoalFormat.duration(minutes: Double(target))) limit today.")
        }
    }
}
