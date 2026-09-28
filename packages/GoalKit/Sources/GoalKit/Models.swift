import Foundation

public enum GoalType: String, Codable, CaseIterable, Sendable, Identifiable {
    case steps, workout, screenTime, pickups, overeating, wakeup, phoneBeforeBed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .steps: "Steps"
        case .workout: "Workout"
        case .screenTime: "Screen time"
        case .pickups: "Pickups"
        case .overeating: "Over-eating"
        case .wakeup: "Wake up"
        case .phoneBeforeBed: "Phone before bed"
        }
    }

    public var symbol: String {
        switch self {
        case .steps: "figure.walk"
        case .workout: "figure.run"
        case .screenTime: "iphone"
        case .pickups: "hand.raised"
        case .overeating: "fork.knife"
        case .wakeup: "alarm"
        case .phoneBeforeBed: "iphone.slash"
        }
    }

    public var direction: GoalDirection {
        switch self {
        case .steps, .workout: .atLeast
        case .screenTime, .pickups, .overeating, .wakeup, .phoneBeforeBed: .atMost
        }
    }

    public var unit: String {
        switch self {
        case .steps: "steps"
        case .workout, .screenTime: "min"
        case .pickups: "pickups"
        case .overeating: ""
        case .wakeup: "time"
        case .phoneBeforeBed: "min"
        }
    }
}

public enum GoalDirection: String, Codable, Sendable {
    case atLeast, atMost
}

/// How the workout goal counts: at least `target` workouts (walks don't count), one logged workout
/// at least `target` minutes long, or Apple exercise minutes of at least `target`.
public enum WorkoutMeasure: String, Codable, CaseIterable, Sendable {
    case workoutCount, longestWorkout, exerciseMinutes

    public var title: String {
        switch self {
        case .workoutCount: "Number of workouts"
        case .longestWorkout: "One workout of at least N minutes"
        case .exerciseMinutes: "Exercise minutes"
        }
    }

    /// A sensible target when switching to this measure.
    public var defaultTarget: Double {
        self == .workoutCount ? 1 : 30
    }
}

/// Which HealthKit workouts count toward the number-of-workouts goal.
public enum WorkoutRules {
    /// `HKWorkoutActivityType.walking`. Walks are too easy to log by accident to count as a workout.
    public static let excludedActivityTypes: Set<Int> = [52]
    public static let excludedActivityNames: Set<String> = ["Walking"]

    /// Uses the stored activity type, falling back to the name for readings recorded before it was stored.
    public static func counts(_ metric: Metric) -> Bool {
        if let raw = metric.detail?["activityType"].flatMap(Int.init) {
            return !excludedActivityTypes.contains(raw)
        }
        return !excludedActivityNames.contains(metric.detail?["activity"] ?? "")
    }
}

/// Days of the week as `Calendar` weekday numbers: 1 = Sunday … 7 = Saturday.
public struct Weekdays: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public init(weekday: Int) { self.init(rawValue: 1 << (weekday - 1)) }

    public static let all = Weekdays(rawValue: 0b111_1111)
    public static let weekdays = Weekdays([2, 3, 4, 5, 6].map(Weekdays.init(weekday:)))

    public init<S: Sequence>(_ days: S) where S.Element == Weekdays {
        self.init(rawValue: days.reduce(0) { $0 | $1.rawValue })
    }

    public func contains(weekday: Int) -> Bool { contains(Weekdays(weekday: weekday)) }
}

public struct Goal: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ownerId: String
    public var type: GoalType
    public var direction: GoalDirection
    /// Steps, minutes, pickups; minutes after local midnight for wakeup; unused for overeating.
    public var target: Double
    public var unit: String
    public var active: Bool
    /// Days the goal applies. Days outside it evaluate to `.off`.
    public var days: Weekdays
    public var workoutMeasure: WorkoutMeasure?
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, ownerId: String, type: GoalType, target: Double,
                active: Bool = true, days: Weekdays = .all, workoutMeasure: WorkoutMeasure? = nil,
                updatedAt: Date = .now) {
        self.id = id
        self.ownerId = ownerId
        self.type = type
        self.direction = type.direction
        self.target = target
        self.unit = type.unit
        self.active = active
        self.days = days
        self.workoutMeasure = type == .workout ? (workoutMeasure ?? .workoutCount) : nil
        self.updatedAt = updatedAt
    }

    public func applies(on day: DayKey, calendar: Calendar = .current) -> Bool {
        active && days.contains(weekday: day.weekday(calendar: calendar))
    }

    /// Each person has one goal per type, and its id is the type, so every device (and the server)
    /// agrees on it without coordinating.
    public static func canonicalId(_ type: GoalType) -> String { type.rawValue }

    public var hasCanonicalId: Bool { id == Goal.canonicalId(type) }

    /// The starting set for a new install: 10,000 steps, under 2 hours of screen time, under 50
    /// pickups, one 20-minute workout, up by 6:00 on weekdays, no over-eating, and no phone in the
    /// 30 minutes before falling asleep.
    public static func defaults(ownerId: String) -> [Goal] {
        [
            Goal(id: canonicalId(.steps), ownerId: ownerId, type: .steps, target: 10_000),
            Goal(id: canonicalId(.workout), ownerId: ownerId, type: .workout, target: 20, workoutMeasure: .longestWorkout),
            Goal(id: canonicalId(.screenTime), ownerId: ownerId, type: .screenTime, target: 120),
            Goal(id: canonicalId(.pickups), ownerId: ownerId, type: .pickups, target: 50),
            Goal(id: canonicalId(.overeating), ownerId: ownerId, type: .overeating, target: 0),
            Goal(id: canonicalId(.wakeup), ownerId: ownerId, type: .wakeup, target: 6 * 60, days: .weekdays),
            Goal(id: canonicalId(.phoneBeforeBed), ownerId: ownerId, type: .phoneBeforeBed, target: 30),
        ]
    }
}

public enum MetricSource: String, Codable, Sendable {
    /// Read from HealthKit.
    case healthKit
    /// A DeviceActivity threshold crossing.
    case threshold
    /// OCR of the Snapshot screen.
    case snapshot
    /// Answered in the recap or a notification.
    case manual
}

/// One raw reading or entry. `id` is deterministic per reading, so re-uploading the same reading
/// overwrites it rather than duplicating it.
public struct Metric: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ownerId: String
    public var date: DayKey
    public var type: GoalType
    public var source: MetricSource
    public var value: Double
    public var recordedAt: Date
    public var detail: [String: String]?

    public init(id: String, ownerId: String, date: DayKey, type: GoalType, source: MetricSource,
                value: Double, recordedAt: Date = .now, detail: [String: String]? = nil) {
        self.id = id
        self.ownerId = ownerId
        self.date = date
        self.type = type
        self.source = source
        self.value = value
        self.recordedAt = recordedAt
        self.detail = detail
    }

    /// DynamoDB sort key: one query by prefix returns a day, a week, or a month.
    public var sortKey: String { "\(date.rawValue)#\(type.rawValue)#\(id)" }
}

public enum MetricKind {
    public static let key = "kind"
    public static let hourlySteps = "hourlySteps"
    public static let exerciseMinutes = "exerciseMinutes"
    public static let workout = "workout"
    public static let pickupsSelfReport = "pickupsSelfReport"
}

public enum DayStatus: String, Codable, Sendable {
    case hit, missed, pending
    /// The goal doesn't apply on this day (e.g. a wakeup goal on a weekend).
    case off
}

public enum Confidence: String, Codable, Sendable {
    case exact, range, selfReported
    /// Set by hand, overriding measured data.
    case manual
}

public struct DaySummary: Codable, Hashable, Sendable, Identifiable {
    public var ownerId: String
    public var date: DayKey
    public var goalId: String
    public var goalType: GoalType
    public var status: DayStatus
    public var value: Double?
    /// Upper end of a range result (screen time from thresholds only).
    public var upperValue: Double?
    public var confidence: Confidence
    public var updatedAt: Date

    public init(ownerId: String, date: DayKey, goalId: String, goalType: GoalType, status: DayStatus,
                value: Double?, upperValue: Double? = nil, confidence: Confidence, updatedAt: Date = .now) {
        self.ownerId = ownerId
        self.date = date
        self.goalId = goalId
        self.goalType = goalType
        self.status = status
        self.value = value
        self.upperValue = upperValue
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    public var id: String { sortKey }
    public var sortKey: String { "\(date.rawValue)#\(goalId)" }

    /// True when two summaries say the same thing, ignoring when they were computed.
    public func sameResult(as other: DaySummary) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

public struct UserProfile: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var timeZone: String

    public init(id: String, displayName: String, timeZone: String = TimeZone.current.identifier) {
        self.id = id
        self.displayName = displayName
        self.timeZone = timeZone
    }
}

public struct Share: Codable, Hashable, Sendable, Identifiable {
    public var ownerId: String
    public var viewerId: String
    public var ownerName: String?
    public var viewerName: String?
    public var createdAt: Date?

    public var id: String { "\(ownerId)#\(viewerId)" }

    public init(ownerId: String, viewerId: String, ownerName: String? = nil, viewerName: String? = nil, createdAt: Date? = nil) {
        self.ownerId = ownerId
        self.viewerId = viewerId
        self.ownerName = ownerName
        self.viewerName = viewerName
        self.createdAt = createdAt
    }
}

public struct Invite: Codable, Hashable, Sendable {
    public var code: String
    public var ownerId: String
    public var expiresAt: Date

    public init(code: String, ownerId: String, expiresAt: Date) {
        self.code = code
        self.ownerId = ownerId
        self.expiresAt = expiresAt
    }
}
