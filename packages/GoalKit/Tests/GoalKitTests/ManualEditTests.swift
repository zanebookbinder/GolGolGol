import Foundation
import Testing
@testable import GoalKit

struct ManualEditTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    let day = DayKey(rawValue: "2026-09-21")!
    var later: Date { calendar.date(byAdding: .day, value: 7, to: day.start(calendar: calendar))! }

    func edit(_ type: GoalType, _ kind: String, _ value: Double) -> Metric {
        Metric(id: MetricKind.overrideId(type, day), ownerId: "u", date: day, type: type, source: .manual,
               value: value, detail: [MetricKind.key: kind])
    }

    func steps(_ value: Double) -> Metric {
        Metric(id: "steps:\(day.rawValue)T09", ownerId: "u", date: day, type: .steps, source: .healthKit, value: value,
               detail: [MetricKind.key: MetricKind.hourlySteps])
    }

    @Test func valueEditOverridesMeasuredData() {
        let goal = Goal(ownerId: "u", type: .steps, target: 10_000)
        let s = GoalEvaluator.evaluate(goal, metrics: [steps(3_000), edit(.steps, MetricKind.overrideValue, 11_200)],
                                       day: day, now: later, calendar: calendar)
        #expect(s.status == .hit && s.value == 11_200 && s.confidence == .manual)
    }

    @Test func statusEditMarksDoneOrMissed() {
        let goal = Goal(ownerId: "u", type: .screenTime, target: 120)
        let s = GoalEvaluator.evaluate(goal, metrics: [edit(.screenTime, MetricKind.overrideStatus, 0)], day: day, now: later, calendar: calendar)
        #expect(s.status == .missed)
        #expect(GoalFormat.value(s, goal: goal) == "Missed")
    }

    @Test func clearingEditRestoresMeasuredData() {
        let goal = Goal(ownerId: "u", type: .steps, target: 10_000)
        let s = GoalEvaluator.evaluate(goal, metrics: [steps(3_000), edit(.steps, MetricKind.overrideCleared, 0)],
                                       day: day, now: later, calendar: calendar)
        #expect(s.status == .missed && s.value == 3_000 && s.confidence == .exact)
    }

    @Test func clearedEditIsNotMistakenForARecapAnswer() {
        let goal = Goal(ownerId: "u", type: .overeating, target: 0)
        let s = GoalEvaluator.evaluate(goal, metrics: [edit(.overeating, MetricKind.overrideCleared, 0)], day: day, now: later, calendar: calendar)
        #expect(s.status == .pending)
    }

    @Test func clearedAnswerLeavesGoalUnanswered() {
        let goal = Goal(ownerId: "u", type: .overeating, target: 0)
        let cleared = Metric(id: MetricKind.answerId(.overeating, day), ownerId: "u", date: day, type: .overeating,
                             source: .manual, value: 0, detail: [MetricKind.key: MetricKind.answerCleared])
        let metrics = [edit(.overeating, MetricKind.overrideCleared, 0), cleared]
        let s = GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: later, calendar: calendar)
        #expect(s.status == .pending)
        #expect(GoalFormat.value(s, goal: goal) == "Answer in recap")
    }

    @Test func wakeupEditUsesTolerance() {
        let goal = Goal(ownerId: "u", type: .wakeup, target: 420, days: .all)
        let s = GoalEvaluator.evaluate(goal, metrics: [edit(.wakeup, MetricKind.overrideValue, 424)], day: day, now: later, calendar: calendar)
        #expect(s.status == .hit)
    }
}
