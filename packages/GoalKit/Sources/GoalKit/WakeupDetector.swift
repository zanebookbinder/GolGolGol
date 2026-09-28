import Foundation

/// A span of time HealthKit recorded as asleep (core, deep, REM, or unspecified; not in-bed or awake).
public struct SleepInterval: Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Finds the morning's final wake time from sleep data.
///
/// Samples are grouped into sessions (gaps shorter than `maxGap` count as the same sleep, so briefly
/// waking at 6:50 and dozing until 7:30 gives 7:30). The main session is the one with the most
/// sleep that ends on the given day before `latestWakeHour`, which keeps afternoon naps out.
/// The wake time is that session's latest end.
public enum WakeupDetector {
    public static let maxGap: TimeInterval = 60 * 60
    public static let latestWakeHour = 16

    /// Where to look for the night that ends on `day`: 6pm the evening before, to `latestWakeHour`.
    public static func searchWindow(for day: DayKey, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: .hour, value: -6, to: day.start(calendar: calendar))!
        let end = calendar.date(byAdding: .hour, value: latestWakeHour, to: day.start(calendar: calendar))!
        return DateInterval(start: start, end: end)
    }

    public static func wakeTime(from samples: [SleepInterval], on day: DayKey, calendar: Calendar = .current) -> Date? {
        let window = searchWindow(for: day, calendar: calendar)
        let dayStart = day.start(calendar: calendar)
        let sorted = samples
            .filter { $0.end > $0.start && $0.end > window.start && $0.start < window.end }
            .sorted { $0.start < $1.start }

        var sessions: [(end: Date, asleep: TimeInterval)] = []
        for sample in sorted {
            if let last = sessions.last, sample.start.timeIntervalSince(last.end) <= maxGap {
                sessions[sessions.count - 1].end = max(last.end, sample.end)
                sessions[sessions.count - 1].asleep += sample.end.timeIntervalSince(sample.start)
            } else {
                sessions.append((sample.end, sample.end.timeIntervalSince(sample.start)))
            }
        }

        return sessions
            .filter { $0.end >= dayStart && $0.end <= window.end }
            .max { $0.asleep < $1.asleep }?
            .end
    }

    /// Minutes after local midnight, the unit wakeup goals and metrics use.
    public static func minutesAfterMidnight(_ date: Date, on day: DayKey, calendar: Calendar = .current) -> Double {
        (date.timeIntervalSince(day.start(calendar: calendar)) / 60).rounded()
    }
}
