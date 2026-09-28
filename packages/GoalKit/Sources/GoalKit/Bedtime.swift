import Foundation

extension MetricKind {
    /// The evening schedule (9pm–3am) was running that night, so "no crossings" means no phone use.
    public static let eveningMonitoring = "eveningMonitoring"
    /// Start of the night's main sleep, from HealthKit.
    public static let sleepOnset = "sleepOnset"
    /// Bedtime corrected by hand.
    public static let sleepOnsetEdit = "sleepOnsetEdit"
    /// Last phone use before sleep corrected by hand (value -1 = none that evening).
    public static let lastUseEdit = "lastUseEdit"
}

/// The "no phone before bed" goal, measured without any input:
/// - an evening Screen Time schedule (9pm–3am) with a threshold every 2 minutes of use; each crossing
///   is stored with the time it happened, so the latest crossing before sleep is roughly the last use;
/// - the start of the night's main sleep from HealthKit.
///
/// Times are stored as minutes after the start of the evening's date (so 10:47pm is 1367 and
/// 12:30am is 1470), filed under that evening even after midnight. Either time can be corrected by hand.
public enum Bedtime {
    public static let windowStartMinutes: Double = 21 * 60    // 9pm
    public static let windowEndMinutes: Double = 27 * 60      // 3am the next morning
    public static let stepMinutes = 2
    public static let maxUseMinutes = 240
    /// With no sleep data by this time the next day, the recap asks instead.
    public static let deadlineHour = 14

    /// Cumulative minutes of evening use at which a threshold fires.
    public static var ladder: [Int] { Array(stride(from: stepMinutes, through: maxUseMinutes, by: stepMinutes)) }

    /// The evening an instant belongs to: anything before noon counts toward the previous evening.
    public static func night(for date: Date, calendar: Calendar = .current) -> DayKey {
        let day = DayKey(date, calendar: calendar)
        return calendar.component(.hour, from: date) < 12 ? day.adding(days: -1, calendar: calendar) : day
    }

    public static func minutes(of date: Date, night: DayKey, calendar: Calendar = .current) -> Double {
        (date.timeIntervalSince(night.start(calendar: calendar)) / 60).rounded()
    }

    public static func date(minutes: Double, night: DayKey, calendar: Calendar = .current) -> Date {
        night.start(calendar: calendar).addingTimeInterval(minutes * 60)
    }

    public static func crossingId(_ night: DayKey, _ threshold: Int) -> String { "evening:\(night.rawValue):\(threshold)" }
    public static func monitoringId(_ night: DayKey) -> String { "evening-monitoring:\(night.rawValue)" }
    public static func onsetId(_ night: DayKey) -> String { "sleeponset:\(night.rawValue)" }
    public static func onsetEditId(_ night: DayKey) -> String { "sleeponset-edit:\(night.rawValue)" }
    public static func lastUseEditId(_ night: DayKey) -> String { "lastuse-edit:\(night.rawValue)" }

    /// A threshold crossing during the evening schedule.
    public static func crossing(threshold: Int, at date: Date = .now, ownerId: String, calendar: Calendar = .current) -> Metric {
        let night = night(for: date, calendar: calendar)
        return Metric(id: crossingId(night, threshold), ownerId: ownerId, date: night, type: .phoneBeforeBed,
                      source: .threshold, value: minutes(of: date, night: night, calendar: calendar), recordedAt: date,
                      detail: ["usedMinutes": String(threshold)])
    }

    /// The evening schedule is running (posted when it starts, and when the app registers it).
    public static func monitoringMarker(at date: Date = .now, ownerId: String, calendar: Calendar = .current) -> Metric {
        let night = night(for: date, calendar: calendar)
        return Metric(id: monitoringId(night), ownerId: ownerId, date: night, type: .phoneBeforeBed, source: .threshold,
                      value: 0, recordedAt: date, detail: [MetricKind.key: MetricKind.eveningMonitoring])
    }

    /// The start of the night's main sleep, from HealthKit.
    public static func onset(_ date: Date, night: DayKey, ownerId: String, calendar: Calendar = .current) -> Metric {
        Metric(id: onsetId(night), ownerId: ownerId, date: night, type: .phoneBeforeBed, source: .healthKit,
               value: minutes(of: date, night: night, calendar: calendar), recordedAt: date,
               detail: [MetricKind.key: MetricKind.sleepOnset])
    }

    /// What the evaluator found for a night, for showing on the goal's page.
    public struct Findings: Equatable, Sendable {
        /// Minutes after the evening's midnight.
        public var sleepOnset: Double?
        /// Last phone use before sleep; nil means none that evening.
        public var lastUse: Double?
        public var onsetEdited: Bool
        public var lastUseEdited: Bool
        /// Whether the evening schedule ran (or a last-use time was entered), so "no use" is meaningful.
        public var monitored: Bool
    }

    public static func findings(metrics: [Metric], night: DayKey) -> Findings {
        let relevant = metrics.filter { $0.date == night && $0.type == .phoneBeforeBed }
        let onsetEdit = relevant.first { $0.id == onsetEditId(night) && $0.detail?[MetricKind.key] == MetricKind.sleepOnsetEdit }
        let onset = onsetEdit?.value ?? relevant.first { $0.id == onsetId(night) }?.value
        let lastUseEdit = relevant.first { $0.id == lastUseEditId(night) && $0.detail?[MetricKind.key] == MetricKind.lastUseEdit }
        let crossings = relevant.filter { $0.source == .threshold && $0.detail?[MetricKind.key] != MetricKind.eveningMonitoring }
        let monitored = !crossings.isEmpty || relevant.contains { $0.id == monitoringId(night) } || lastUseEdit != nil

        let lastUse: Double?
        if let lastUseEdit {
            lastUse = lastUseEdit.value < 0 ? nil : lastUseEdit.value
        } else {
            // The latest use at or before falling asleep (use after waking in the night doesn't count).
            lastUse = crossings.map(\.value).filter { onset == nil || $0 <= onset! }.max()
        }
        return Findings(sleepOnset: onset, lastUse: lastUse, onsetEdited: onsetEdit != nil,
                        lastUseEdited: lastUseEdit != nil, monitored: monitored)
    }

    static func evaluate(_ goal: Goal, metrics: [Metric], night: DayKey, now: Date, calendar: Calendar,
                         summary: (DayStatus, Double?, Double?, Confidence) -> DaySummary) -> DaySummary {
        let found = findings(metrics: metrics, night: night)
        let deadline = calendar.date(byAdding: .hour, value: 24 + deadlineHour, to: night.start(calendar: calendar))!
        // "Waiting" is pending with exact confidence; "needs an answer" is pending with selfReported,
        // which makes it a recap question.
        let unknown = summary(.pending, found.sleepOnset, found.lastUse, now >= deadline ? .selfReported : .exact)

        guard let onset = found.sleepOnset else { return unknown }
        let windowStart = onset - goal.target
        // Phone off, or asleep outside the monitored evening, and no hand-entered last use: can't tell.
        if !found.lastUseEdited && (!found.monitored || windowStart < windowStartMinutes || onset > windowEndMinutes) {
            return unknown
        }
        let usedInWindow = found.lastUse.map { $0 > windowStart } ?? false
        let confidence: Confidence = found.onsetEdited || found.lastUseEdited ? .manual : .exact
        return summary(usedInWindow ? .missed : .hit, onset, found.lastUse, confidence)
    }
}
