import Foundation
import Testing
@testable import GoalKit

struct CelebrationTests {
    let today = DayKey(rawValue: "2026-09-28")!
    let goals = Goal.defaults(ownerId: "u")

    func results(_ statuses: [GoalType: DayStatus], value: Double? = 10) -> [GoalType: DaySummary] {
        Dictionary(uniqueKeysWithValues: statuses.map { type, status in
            (type, DaySummary(ownerId: "u", date: today, goalId: type.rawValue, goalType: type, status: status,
                              value: value, confidence: .exact))
        })
    }

    var perfectTonight: [GoalType: DayStatus] {
        [.steps: .hit, .workout: .hit, .screenTime: .pending, .pickups: .pending, .overeating: .hit,
         .wakeup: .hit, .phoneBeforeBed: .pending]
    }

    @Test func goooolWhenEverythingIsDoneOrStillOnTrack() {
        let tonight = results(perfectTonight)
        #expect(Celebrations.best(for: today, goals: goals) { goal, day in day == today ? tonight[goal.type] : nil } == .goooool)
    }

    @Test func hatTrickAfterTwoPerfectDaysBefore() {
        let tonight = results(perfectTonight)
        var settled = perfectTonight.mapValues { _ in DayStatus.hit }
        settled[.wakeup] = .off // weekend: doesn't count against it
        let earlier = results(settled)
        #expect(Celebrations.best(for: today, goals: goals) { goal, day in day == today ? tonight[goal.type] : earlier[goal.type] } == .hatTrick)
    }

    @Test func nothingWhenAGoalIsMissedOrNotDone() {
        var statuses = perfectTonight
        statuses[.screenTime] = .missed
        let missed = results(statuses)
        #expect(Celebrations.best(for: today, goals: goals) { goal, _ in missed[goal.type] } == nil)

        statuses = perfectTonight
        statuses[.overeating] = .pending // not answered yet
        let unanswered = results(statuses)
        #expect(Celebrations.best(for: today, goals: goals) { goal, _ in unanswered[goal.type] } == nil)
    }
}
