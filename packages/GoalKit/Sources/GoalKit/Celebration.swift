import Foundation

/// Football-flavored cheers for the nightly recap.
public enum Celebration: String, Sendable, CaseIterable {
    /// Three perfect days in a row (today plus the two before).
    case hatTrick
    /// Every goal done today.
    case goooool
    /// Screen time and pickups both kept under their limits.
    case cleanSheet

    public var title: String {
        switch self {
        case .hatTrick: "Hat trick!"
        case .goooool: "GOOOOOL!"
        case .cleanSheet: "Clean sheet!"
        }
    }

    public var message: String {
        switch self {
        case .hatTrick: "Three perfect days in a row."
        case .goooool: "Every goal done today."
        case .cleanSheet: "Screen time and pickups kept under your limits."
        }
    }

    public var symbol: String {
        switch self {
        case .hatTrick: "trophy.fill"
        case .goooool: "soccerball"
        case .cleanSheet: "hand.raised.fill"
        }
    }
}

public enum Celebrations {
    /// Goals whose result isn't final at recap time: screen time and pickups settle at midnight,
    /// phone-before-bed the next morning. Tonight they count as long as they haven't been missed.
    static let settleLater: Set<GoalType> = [.screenTime, .pickups, .phoneBeforeBed]

    /// The best cheer for `day` (tonight's recap), or nil. `summary` looks up a goal's result.
    public static func best(for day: DayKey, goals: [Goal], calendar: Calendar = .current,
                            summary: (Goal, DayKey) -> DaySummary?) -> Celebration? {
        guard onTrack(day, goals: goals, final: false, summary: summary) else {
            return cleanSheet(day, goals: goals, summary: summary) ? .cleanSheet : nil
        }
        let previous = [1, 2].map { day.adding(days: -$0, calendar: calendar) }
        if previous.allSatisfy({ onTrack($0, goals: goals, final: true, summary: summary) }) { return .hatTrick }
        return .goooool
    }

    /// Every goal that applies is completed. With `final == false` (tonight), goals that settle
    /// later also count if they're still in progress rather than missed. Needs at least one goal.
    static func onTrack(_ day: DayKey, goals: [Goal], final: Bool, summary: (Goal, DayKey) -> DaySummary?) -> Bool {
        var counted = 0
        for goal in goals where goal.active {
            switch summary(goal, day)?.status {
            case .off:
                continue
            case .hit:
                counted += 1
            case .pending where !final && settleLater.contains(goal.type):
                counted += 1
            default:
                return false
            }
        }
        return counted > 0
    }

    /// Both screen time and pickups completed or still under the limit (and at least one tracked).
    static func cleanSheet(_ day: DayKey, goals: [Goal], summary: (Goal, DayKey) -> DaySummary?) -> Bool {
        let relevant = goals.filter { $0.active && ($0.type == .screenTime || $0.type == .pickups) }
        guard !relevant.isEmpty else { return false }
        return relevant.allSatisfy { goal in
            switch summary(goal, day)?.status {
            case .hit, .off: true
            // Under the limit so far: screen time has data, pickups has a snapshot count.
            case .pending: summary(goal, day)?.value != nil
            default: false
            }
        }
    }
}
