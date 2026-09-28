import DeviceActivity
import FamilyControls
import Foundation
import GoalKit

/// Registers the daily screen time schedule with a ladder of threshold events built from the goal.
enum Monitoring {
    static let activity = DeviceActivityName("daily")

    /// Event names encode their threshold so the monitor extension can recover it: "t105" = 105 minutes.
    static func eventName(minutes: Int) -> DeviceActivityEvent.Name {
        DeviceActivityEvent.Name("t\(minutes)")
    }

    static func minutes(from event: DeviceActivityEvent.Name) -> Int? {
        Int(event.rawValue.dropFirst())
    }

    /// Rebuilds the schedule from the saved goal and selection. Called on launch, when the goal
    /// changes, and at each midnight from the extension.
    static func start() throws {
        let target = MonitoringSettings.targetMinutes
        let selection = MonitoringSettings.selection
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minutes in ThresholdLadder.minutes(goal: target) {
            events[eventName(minutes: minutes)] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(hour: minutes / 60, minute: minutes % 60),
                // Count usage from earlier today, so re-registering mid-day keeps the day's total right.
                includesPastActivity: true
            )
        }
        let center = DeviceActivityCenter()
        center.stopMonitoring([activity])
        try center.startMonitoring(activity, during: schedule, events: events)
        MonitoringSettings.registeredLadder = ThresholdLadder.minutes(goal: target)
    }

    static var isActive: Bool {
        DeviceActivityCenter().activities.contains(activity)
    }

    // MARK: Evening (phone before bed)

    /// A second schedule, 9pm–3am, with a threshold every 2 minutes of use. Each crossing is stored
    /// with its time, so the latest one before sleep is roughly the last phone use.
    static let eveningActivity = DeviceActivityName("evening")

    static func eveningEventName(minutes: Int) -> DeviceActivityEvent.Name {
        DeviceActivityEvent.Name("e\(minutes)")
    }

    static func startEvening() throws {
        let selection = MonitoringSettings.selection
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 21, minute: 0),
            intervalEnd: DateComponents(hour: 3, minute: 0),
            repeats: true
        )
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for minutes in Bedtime.ladder {
            events[eveningEventName(minutes: minutes)] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(hour: minutes / 60, minute: minutes % 60),
                includesPastActivity: true
            )
        }
        let center = DeviceActivityCenter()
        center.stopMonitoring([eveningActivity])
        try center.startMonitoring(eveningActivity, during: schedule, events: events)
        MonitoringSettings.registeredEveningLadder = Bedtime.ladder
    }

    static func stopEvening() {
        DeviceActivityCenter().stopMonitoring([eveningActivity])
        MonitoringSettings.registeredEveningLadder = []
    }

    static var isEveningActive: Bool {
        DeviceActivityCenter().activities.contains(eveningActivity)
    }

    /// Threshold events only count the apps and categories picked in the Screen Time picker; with
    /// nothing picked they never fire.
    static var hasSelection: Bool {
        let selection = MonitoringSettings.selection
        return !selection.categoryTokens.isEmpty || !selection.applicationTokens.isEmpty || !selection.webDomainTokens.isEmpty
    }

    /// Marks today as monitored, so a day with no crossings evaluates as under the first threshold
    /// rather than unknown.
    static func monitoringMarker(for day: DayKey = .today(), ownerId: String) -> Metric {
        Metric(id: "monitoring:\(day.rawValue)", ownerId: ownerId, date: day, type: .screenTime, source: .threshold,
               value: 0, detail: [MetricKind.key: MetricKind.monitoring])
    }

    static func crossing(minutes: Int, day: DayKey = .today(), ownerId: String) -> Metric {
        Metric(id: "threshold:\(day.rawValue):\(minutes)", ownerId: ownerId, date: day, type: .screenTime,
               source: .threshold, value: Double(minutes))
    }
}

/// Monitoring inputs, kept in the App Group so the extension can rebuild the schedule at midnight.
enum MonitoringSettings {
    private static let selectionKey = "selection"
    private static let targetKey = "screenTimeTarget"
    private static let registeredKey = "registeredLadder"
    private static let ownerKey = "ownerId"

    static var selection: FamilyActivitySelection {
        get {
            guard let data = AppGroup.defaults.data(forKey: selectionKey),
                  let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
            else { return FamilyActivitySelection() }
            return selection
        }
        set { AppGroup.defaults.set(try? JSONEncoder().encode(newValue), forKey: selectionKey) }
    }

    static var targetMinutes: Int {
        get { AppGroup.defaults.object(forKey: targetKey) as? Int ?? 120 }
        set { AppGroup.defaults.set(newValue, forKey: targetKey) }
    }

    /// The thresholds the current schedule was registered with. Differs from the goal's ladder when the
    /// limit changed or the ladder itself changed in an app update, and then the schedule is rebuilt.
    static var registeredLadder: [Int] {
        get { AppGroup.defaults.array(forKey: registeredKey) as? [Int] ?? [] }
        set { AppGroup.defaults.set(newValue, forKey: registeredKey) }
    }

    static var needsRegistering: Bool {
        registeredLadder != ThresholdLadder.minutes(goal: targetMinutes)
    }

    static var registeredEveningLadder: [Int] {
        get { AppGroup.defaults.array(forKey: "registeredEveningLadder") as? [Int] ?? [] }
        set { AppGroup.defaults.set(newValue, forKey: "registeredEveningLadder") }
    }

    /// The signed-in owner, so the extension can stamp metrics without loading the store.
    static var ownerId: String {
        get { AppGroup.defaults.string(forKey: ownerKey) ?? LocalStore.localOwnerId }
        set { AppGroup.defaults.set(newValue, forKey: ownerKey) }
    }
}
