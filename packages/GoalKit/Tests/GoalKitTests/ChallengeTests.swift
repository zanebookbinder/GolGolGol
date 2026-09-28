import Foundation
import Testing
@testable import GoalKit

struct ChallengeTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    // Mon 2026-09-21 … Sun 2026-09-27; "today" is Fri 2026-09-25.
    let challenge = Challenge(name: "Week", start: DayKey(rawValue: "2026-09-21")!, end: DayKey(rawValue: "2026-09-27")!)
    let today = DayKey(rawValue: "2026-09-25")!

    func summaries(_ goal: Goal, _ statuses: [String: DayStatus]) -> [String: DaySummary] {
        Dictionary(uniqueKeysWithValues: statuses.map { day, status in
            (day, DaySummary(ownerId: "u", date: DayKey(rawValue: day)!, goalId: goal.id, goalType: goal.type,
                             status: status, value: nil, confidence: .exact))
        })
    }

    @Test func countsHitsMissesUnansweredAndRemaining() {
        let steps = Goal(id: "steps", ownerId: "u", type: .steps, target: 10_000)
        let byDay = summaries(steps, ["2026-09-21": .hit, "2026-09-22": .hit, "2026-09-23": .missed, "2026-09-25": .pending])
        let stats = ChallengeStats.compute(challenge: challenge, goals: [steps], today: today, calendar: calendar) { _, day in byDay[day.rawValue] }
        let s = stats.goals[0]
        #expect(s.hits == 2)
        #expect(s.misses == 1)
        #expect(s.unanswered == 1)   // Thursday: no result
        #expect(s.remaining == 3)    // today (pending), Saturday, Sunday
        #expect(s.rate == 0.5)
        #expect(s.bestStreak == 2)
        #expect(s.bestPossibleRate == 5.0 / 7.0)
    }

    @Test func offDaysDontCount() {
        let wake = Goal(id: "wake", ownerId: "u", type: .wakeup, target: 420, days: .weekdays)
        let byDay = summaries(wake, ["2026-09-21": .hit, "2026-09-22": .hit, "2026-09-23": .hit, "2026-09-24": .hit, "2026-09-25": .hit])
        let stats = ChallengeStats.compute(challenge: challenge, goals: [wake], today: today, calendar: calendar) { _, day in byDay[day.rawValue] }
        let s = stats.goals[0]
        #expect(s.offDays == 2)
        #expect(s.remaining == 0)
        #expect(s.rate == 1)
        #expect(s.currentStreak == 5)
    }

    @Test func perfectDaysAndOverallRate() {
        let steps = Goal(id: "steps", ownerId: "u", type: .steps, target: 10_000)
        let food = Goal(id: "food", ownerId: "u", type: .overeating, target: 0)
        let a = summaries(steps, ["2026-09-21": .hit, "2026-09-22": .hit])
        let b = summaries(food, ["2026-09-21": .hit, "2026-09-22": .missed])
        let stats = ChallengeStats.compute(challenge: challenge, goals: [steps, food], today: DayKey(rawValue: "2026-09-23")!, calendar: calendar) { goal, day in
            (goal.id == "steps" ? a : b)[day.rawValue]
        }
        #expect(stats.perfectDays == 1)
        #expect(stats.overallRate == 3.0 / 4.0)
    }

    @Test func averagesFinishedDaysOnly() {
        let steps = Goal(id: "steps", ownerId: "u", type: .steps, target: 10_000)
        func s(_ day: String, _ status: DayStatus, _ value: Double) -> DaySummary {
            DaySummary(ownerId: "u", date: DayKey(rawValue: day)!, goalId: "steps", goalType: .steps, status: status, value: value, confidence: .exact)
        }
        let byDay = ["2026-09-21": s("2026-09-21", .hit, 12_000), "2026-09-22": s("2026-09-22", .missed, 8_000),
                     "2026-09-25": s("2026-09-25", .pending, 1_000)]
        let stats = ChallengeStats.compute(challenge: challenge, goals: [steps], today: today, calendar: calendar) { _, day in byDay[day.rawValue] }
        #expect(stats.goals[0].average == 10_000)   // today's partial 1,000 is left out
        #expect(stats.goals[0].valueDays == 2)
    }

    @Test func screenTimeRangeAveragesMidpointAsEstimate() {
        let screen = Goal(id: "screen", ownerId: "u", type: .screenTime, target: 120)
        let ranged = DaySummary(ownerId: "u", date: DayKey(rawValue: "2026-09-21")!, goalId: "screen", goalType: .screenTime,
                                status: .hit, value: 90, upperValue: 120, confidence: .range)
        let exact = DaySummary(ownerId: "u", date: DayKey(rawValue: "2026-09-22")!, goalId: "screen", goalType: .screenTime,
                               status: .hit, value: 95, confidence: .exact)
        let byDay = ["2026-09-21": ranged, "2026-09-22": exact]
        let stats = ChallengeStats.compute(challenge: challenge, goals: [screen], today: today, calendar: calendar) { _, day in byDay[day.rawValue] }
        #expect(stats.goals[0].average == 100)   // (105 + 95) / 2
        #expect(stats.goals[0].averageIsEstimate)
    }

    @Test func overeatingHasNoAverage() {
        let food = Goal(id: "food", ownerId: "u", type: .overeating, target: 0)
        let byDay = summaries(food, ["2026-09-21": .hit])
        let stats = ChallengeStats.compute(challenge: challenge, goals: [food], today: today, calendar: calendar) { _, day in byDay[day.rawValue] }
        #expect(stats.goals[0].average == nil)
    }

    @Test func phaseAndDayNumber() {
        #expect(challenge.phase(today: today) == .active)
        #expect(challenge.dayNumber(today: today, calendar: calendar) == 5)
        #expect(challenge.totalDays(calendar: calendar) == 7)
        #expect(challenge.phase(today: DayKey(rawValue: "2026-09-28")!) == .finished)
    }
}
