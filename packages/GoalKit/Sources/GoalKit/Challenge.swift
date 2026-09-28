import Foundation

/// A stretch of days (e.g. "October: 30 days") whose goal completion is tracked as a whole.
public struct Challenge: Codable, Hashable, Sendable {
    public var name: String
    public var start: DayKey
    public var end: DayKey
    /// Removing a challenge keeps a tombstone so the removal syncs to the other device.
    public var removed: Bool
    public var updatedAt: Date

    public init(name: String, start: DayKey, end: DayKey, removed: Bool = false, updatedAt: Date = .now) {
        self.name = name
        self.start = start
        self.end = end
        self.removed = removed
        self.updatedAt = updatedAt
    }

    public enum Phase: Sendable {
        case upcoming, active, finished
    }

    public func phase(today: DayKey = .today()) -> Phase {
        today < start ? .upcoming : (today > end ? .finished : .active)
    }

    public func totalDays(calendar: Calendar = .current) -> Int {
        DayKey.range(start, through: end, calendar: calendar).count
    }

    /// 1-based day of the challenge, clamped to its length.
    public func dayNumber(today: DayKey = .today(), calendar: Calendar = .current) -> Int {
        guard today >= start else { return 0 }
        return min(DayKey.range(start, through: today, calendar: calendar).count, totalDays(calendar: calendar))
    }
}

/// One goal's record over a challenge.
public struct GoalChallengeStats: Sendable, Identifiable {
    public var goal: Goal
    public var hits = 0
    public var misses = 0
    /// Past days with no result (e.g. an unanswered recap, or no data).
    public var unanswered = 0
    /// Days the goal didn't apply (e.g. wake-up on a weekend).
    public var offDays = 0
    /// Applicable days still ahead, including today if it isn't settled yet.
    public var remaining = 0
    public var bestStreak = 0
    public var currentStreak = 0
    /// Sum and count of daily values over finished days, for the per-day average.
    public var valueTotal: Double = 0
    public var valueDays = 0
    /// True if any day's value was estimated (screen time from thresholds only).
    public var averageIsEstimate = false

    public var id: String { goal.id }

    /// Average per finished day (steps, workout minutes, screen time minutes, or pickups).
    public var average: Double? {
        valueDays > 0 ? valueTotal / Double(valueDays) : nil
    }

    /// Settled days: hits, misses, and past days with no result.
    public var counted: Int { hits + misses + unanswered }

    /// Hits over counted days, or nil before any day has settled.
    public var rate: Double? {
        counted > 0 ? Double(hits) / Double(counted) : nil
    }

    /// The best rate still reachable if every remaining day is hit.
    public var bestPossibleRate: Double? {
        let total = counted + remaining
        return total > 0 ? Double(hits + remaining) / Double(total) : nil
    }
}

public struct ChallengeStats: Sendable {
    public var challenge: Challenge
    public var goals: [GoalChallengeStats]

    /// All goals together: total hits over total counted days.
    public var overallRate: Double? {
        let counted = goals.reduce(0) { $0 + $1.counted }
        return counted > 0 ? Double(goals.reduce(0) { $0 + $1.hits }) / Double(counted) : nil
    }

    /// Days where every applicable goal was hit.
    public var perfectDays: Int

    public struct DailyValue: Sendable {
        public var value: Double
        public var estimated: Bool

        public init(_ value: Double, estimated: Bool = false) {
            self.value = value
            self.estimated = estimated
        }
    }

    /// Goals whose daily numbers are worth averaging.
    public static let averagedTypes: Set<GoalType> = [.steps, .workout, .screenTime, .pickups]

    /// The number a finished day contributes to the average, from its summary. Screen time known only
    /// as a threshold range uses the middle of the range. Workouts are overridden by the caller with
    /// minutes from the day's workouts, since the summary may hold a workout count.
    public static func summaryValue(_ goal: Goal, _ summary: DaySummary) -> DailyValue? {
        guard averagedTypes.contains(goal.type), let value = summary.value else { return nil }
        if goal.type == .screenTime, summary.confidence == .range {
            return DailyValue(summary.upperValue.map { (value + $0) / 2 } ?? value, estimated: true)
        }
        return DailyValue(value)
    }

    /// `summary` looks up a goal's result for a day, so this works for your data or a partner's.
    /// `dailyValue` supplies the number to average for a finished day that has a result.
    public static func compute(challenge: Challenge, goals: [Goal], today: DayKey = .today(),
                               calendar: Calendar = .current,
                               summary: (Goal, DayKey) -> DaySummary?,
                               dailyValue: (Goal, DayKey, DaySummary) -> DailyValue? = { goal, _, s in summaryValue(goal, s) }) -> ChallengeStats {
        let days = DayKey.range(challenge.start, through: challenge.end, calendar: calendar)
        var stats = goals.map { GoalChallengeStats(goal: $0) }
        var perfect = 0

        for day in days {
            var allHit = true
            var anyCounted = false
            for index in stats.indices {
                let goal = stats[index].goal
                guard goal.days.contains(weekday: day.weekday(calendar: calendar)) else {
                    stats[index].offDays += 1
                    continue
                }
                let result = day > today ? nil : summary(goal, day)
                if day < today, let result, result.status != .off, let daily = dailyValue(goal, day, result) {
                    stats[index].valueTotal += daily.value
                    stats[index].valueDays += 1
                    stats[index].averageIsEstimate = stats[index].averageIsEstimate || daily.estimated
                }
                switch result?.status {
                case .hit:
                    stats[index].hits += 1
                    stats[index].currentStreak += 1
                    stats[index].bestStreak = max(stats[index].bestStreak, stats[index].currentStreak)
                    anyCounted = true
                case .missed:
                    stats[index].misses += 1
                    stats[index].currentStreak = 0
                    allHit = false
                    anyCounted = true
                case .off:
                    stats[index].offDays += 1
                case .pending, nil:
                    if day >= today {
                        // Today (still in progress) and future days are still up for grabs.
                        stats[index].remaining += 1
                    } else {
                        stats[index].unanswered += 1
                        stats[index].currentStreak = 0
                        anyCounted = true
                    }
                    allHit = false
                }
            }
            if allHit && anyCounted { perfect += 1 }
        }
        return ChallengeStats(challenge: challenge, goals: stats, perfectDays: perfect)
    }
}
