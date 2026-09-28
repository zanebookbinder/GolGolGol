import Foundation

extension MetricKind {
    /// Screen time: the DeviceActivity schedule was running that day (so no crossings means under the first threshold).
    public static let monitoring = "monitoring"
    /// Wakeup: answered in the recap because no sleep data arrived.
    public static let wakeupSelfReport = "wakeupSelfReport"
    /// A manual edit that sets the day's value (in the goal's unit); the status follows from the target.
    public static let overrideValue = "overrideValue"
    /// A manual edit that sets the day's status: value 1 = hit, 0 = missed.
    public static let overrideStatus = "overrideStatus"
    /// Undoes a manual edit (the edit's metric id is reused, so this replaces it).
    public static let overrideCleared = "overrideCleared"
    /// Withdraws a recap answer (the answer's metric id is reused, so this replaces it).
    public static let answerCleared = "answerCleared"

    public static func answerId(_ type: GoalType, _ day: DayKey) -> String {
        "\(type.rawValue):answer:\(day.rawValue)"
    }

    public static func overrideId(_ type: GoalType, _ day: DayKey) -> String {
        "\(type.rawValue):override:\(day.rawValue)"
    }
}

/// Turns a day's Metrics into a DaySummary for one goal. The same code runs on the Watch and the iPhone.
public enum GoalEvaluator {
    /// A wakeup counts as hit up to this many minutes after the target.
    public static let wakeupToleranceMinutes: Double = 5

    public static func evaluate(_ goal: Goal, metrics: [Metric], day: DayKey, now: Date = .now,
                                calendar: Calendar = .current) -> DaySummary {
        let relevant = metrics.filter { $0.date == day && $0.type == goal.type }
        let editId = MetricKind.overrideId(goal.type, day)
        /// Recap answers: manual entries other than edits.
        let answers = relevant.filter { $0.id != editId && $0.detail?[MetricKind.key] != MetricKind.answerCleared }
        let over = day.isOver(now: now, calendar: calendar)

        func summary(_ status: DayStatus, _ value: Double?, upper: Double? = nil, _ confidence: Confidence = .exact) -> DaySummary {
            DaySummary(ownerId: goal.ownerId, date: day, goalId: goal.id, goalType: goal.type, status: status,
                       value: value, upperValue: upper, confidence: confidence, updatedAt: now)
        }

        guard goal.applies(on: day, calendar: calendar) else { return summary(.off, nil) }

        // A manual edit beats anything measured.
        if let edit = relevant.first(where: { $0.id == editId }) {
            switch edit.detail?[MetricKind.key] {
            case MetricKind.overrideStatus:
                return summary(edit.value >= 1 ? .hit : .missed, nil, .manual)
            case MetricKind.overrideValue:
                let hit: Bool = switch goal.type {
                case .steps, .workout: edit.value >= goal.target
                case .screenTime, .pickups: edit.value <= goal.target
                case .wakeup: edit.value <= goal.target + wakeupToleranceMinutes
                case .overeating: edit.value < 1
                }
                return summary(hit ? .hit : .missed, edit.value, .manual)
            default:
                break // cleared: fall through to measured data
            }
        }

        switch goal.type {
        case .steps:
            let total = relevant.filter { $0.detail?[MetricKind.key] == MetricKind.hourlySteps }.reduce(0) { $0 + $1.value }
            return summary(atLeast(total, goal.target, over: over), total)

        case .workout:
            let value: Double
            switch goal.workoutMeasure ?? .longestWorkout {
            case .workoutCount:
                value = Double(relevant.filter { $0.detail?[MetricKind.key] == MetricKind.workout && WorkoutRules.counts($0) }.count)
            case .longestWorkout:
                value = relevant.filter { $0.detail?[MetricKind.key] == MetricKind.workout && WorkoutRules.counts($0) }.map(\.value).max() ?? 0
            case .exerciseMinutes:
                value = relevant.filter { $0.detail?[MetricKind.key] == MetricKind.exerciseMinutes }.map(\.value).max() ?? 0
            }
            return summary(atLeast(value, goal.target, over: over), value)

        case .screenTime:
            if let snapshot = latest(relevant, source: .snapshot) {
                return summary(atMost(snapshot.value, goal.target, over: over), snapshot.value)
            }
            let crossed = relevant.filter { $0.source == .threshold && $0.detail?[MetricKind.key] != MetricKind.monitoring }.map { Int($0.value) }
            let monitored = !crossed.isEmpty || relevant.contains { $0.detail?[MetricKind.key] == MetricKind.monitoring }
            guard monitored else { return summary(.pending, nil) }
            let range = ScreenTimeRange(crossed: crossed, ladder: ThresholdLadder.minutes(goal: Int(goal.target)))
            // Crossing the goal's own threshold means usage reached the limit.
            let status: DayStatus = Double(range.lowerMinutes) >= goal.target ? .missed : (over ? .hit : .pending)
            return summary(status, Double(range.lowerMinutes), upper: range.upperMinutes.map(Double.init), .range)

        case .pickups:
            if let snapshot = latest(relevant, source: .snapshot) {
                return summary(atMost(snapshot.value, goal.target, over: over), snapshot.value)
            }
            if let answer = latest(answers, source: .manual) {
                return summary(answer.value >= 1 ? .hit : .missed, nil, .selfReported)
            }
            return summary(.pending, nil)

        case .overeating:
            // Value 1 = overate.
            guard let answer = latest(answers, source: .manual) else { return summary(.pending, nil, .selfReported) }
            return summary(answer.value >= 1 ? .missed : .hit, answer.value, .selfReported)

        case .wakeup:
            if let wake = latest(relevant, source: .healthKit) {
                let status: DayStatus = wake.value <= goal.target + wakeupToleranceMinutes ? .hit : .missed
                return summary(status, wake.value)
            }
            if let answer = latest(answers, source: .manual) {
                return summary(answer.value >= 1 ? .hit : .missed, nil, .selfReported)
            }
            return summary(.pending, nil)
        }
    }

    /// Evaluates every goal for a day.
    public static func evaluate(_ goals: [Goal], metrics: [Metric], day: DayKey, now: Date = .now,
                                calendar: Calendar = .current) -> [DaySummary] {
        goals.filter(\.active).map { evaluate($0, metrics: metrics, day: day, now: now, calendar: calendar) }
    }

    /// Goals the recap should ask about because nothing measured them. A goal that's pending only
    /// because the day isn't over (e.g. a midday pickups snapshot under the limit) isn't a question:
    /// measured data outranks an answer, so answering it couldn't change anything.
    public static func questions(for summaries: [DaySummary]) -> [GoalType] {
        summaries.filter { summary in
            guard summary.status == .pending else { return false }
            switch summary.goalType {
            case .overeating: return true
            case .pickups, .wakeup: return summary.value == nil
            default: return false
            }
        }
        .map(\.goalType)
    }

    private static func latest(_ metrics: [Metric], source: MetricSource) -> Metric? {
        metrics.filter { $0.source == source }.max { $0.recordedAt < $1.recordedAt }
    }

    private static func atLeast(_ value: Double, _ target: Double, over: Bool) -> DayStatus {
        value >= target ? .hit : (over ? .missed : .pending)
    }

    private static func atMost(_ value: Double, _ target: Double, over: Bool) -> DayStatus {
        value > target ? .missed : (over ? .hit : .pending)
    }
}

public enum Streaks {
    /// Consecutive hit days ending today (or yesterday, if today isn't hit yet). Off days are skipped.
    public static func current(goalId: String, summaries: [DaySummary], today: DayKey, calendar: Calendar = .current) -> Int {
        let byDay = Dictionary(summaries.filter { $0.goalId == goalId }.map { ($0.date, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        var day = byDay[today]?.status == .hit ? today : today.adding(days: -1, calendar: calendar)
        var count = 0
        for _ in 0..<3650 {
            switch byDay[day]?.status {
            case .hit: count += 1
            case .off: break
            default: return count
            }
            day = day.adding(days: -1, calendar: calendar)
        }
        return count
    }
}

public enum GoalFormat {
    public static func duration(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(String(format: "%02d", m % 60))"
    }

    public static func clock(minutesAfterMidnight: Double, calendar: Calendar = .current) -> String {
        let m = Int(minutesAfterMidnight.rounded())
        var components = DateComponents()
        components.hour = m / 60
        components.minute = m % 60
        let date = calendar.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    public static func target(_ goal: Goal) -> String {
        switch goal.type {
        case .steps: "\(Int(goal.target).formatted()) steps"
        case .workout:
            switch goal.workoutMeasure ?? .longestWorkout {
            case .workoutCount: goal.target == 1 ? "1 workout" : "\(Int(goal.target)) workouts"
            case .longestWorkout: "A \(Int(goal.target))-min workout"
            case .exerciseMinutes: "\(Int(goal.target)) exercise min"
            }
        case .screenTime: "≤ \(duration(minutes: goal.target))"
        case .pickups: "≤ \(Int(goal.target))"
        case .overeating: "None"
        case .wakeup: "By \(clock(minutesAfterMidnight: goal.target))"
        }
    }

    /// One-line value for a row, e.g. "8,240 / 10,000", "1h45–2h", "6:58 AM".
    public static func value(_ summary: DaySummary?, goal: Goal) -> String {
        guard let summary else { return "–" }
        if summary.status == .off { return "Off today" }
        if summary.confidence == .manual, summary.value == nil {
            return summary.status == .hit ? "Completed" : "Missed"
        }
        switch goal.type {
        case .steps:
            return "\(Int(summary.value ?? 0).formatted()) / \(Int(goal.target).formatted())"
        case .workout:
            let unit = goal.workoutMeasure == .workoutCount ? (goal.target == 1 ? "workout" : "workouts") : "min"
            return "\(Int(summary.value ?? 0)) / \(Int(goal.target)) \(unit)"
        case .screenTime:
            guard let value = summary.value else { return "No data" }
            if summary.confidence == .range {
                guard let upper = summary.upperValue else { return "Over \(duration(minutes: value))" }
                return value == 0 ? "Under \(duration(minutes: upper))" : "\(duration(minutes: value))–\(duration(minutes: upper))"
            }
            return duration(minutes: value)
        case .pickups:
            if let value = summary.value { return "\(Int(value)) / \(Int(goal.target))" }
            return summary.confidence == .selfReported && summary.status != .pending
                ? (summary.status == .hit ? "Under (self-reported)" : "Over (self-reported)") : "Waiting"
        case .overeating:
            switch summary.status {
            case .hit: return "Didn't over-eat"
            case .missed: return "Did over-eat"
            default: return "Answer in recap"
            }
        case .wakeup:
            if let value = summary.value { return clock(minutesAfterMidnight: value) }
            return summary.status == .pending ? "No sleep data" : (summary.status == .hit ? "On time (self-reported)" : "Late (self-reported)")
        }
    }

    /// A per-day average, e.g. "10,835 steps", "75 workout min", "~1h52 screen time".
    public static func average(_ value: Double, goal: Goal, estimated: Bool = false) -> String {
        let approx = estimated ? "~" : ""
        switch goal.type {
        case .steps: return "\(approx)\(Int(value.rounded()).formatted()) steps"
        case .workout:
            return "\(approx)\(Int(value.rounded())) \(goal.workoutMeasure == .exerciseMinutes ? "exercise" : "workout") min"
        case .screenTime: return "\(approx)\(duration(minutes: value)) screen time"
        case .pickups: return "\(approx)\(Int(value.rounded())) pickups"
        case .overeating, .wakeup: return ""
        }
    }

    /// 0…1 progress for rings. At-most goals show how much of the allowance is used.
    public static func progress(_ summary: DaySummary?, goal: Goal) -> Double {
        guard let summary, summary.status != .off else { return 0 }
        switch goal.type {
        case .steps, .workout, .screenTime, .pickups:
            guard goal.target > 0 else { return 0 }
            return min(1, (summary.value ?? 0) / goal.target)
        case .overeating, .wakeup:
            return summary.status == .pending ? 0 : 1
        }
    }
}
