import Foundation
import Testing
@testable import GoalKit

struct GoalEvaluatorTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    // 2026-09-28 is a Monday.
    let day = DayKey(rawValue: "2026-09-28")!

    func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: day.start(calendar: calendar))!
    }

    func metric(_ type: GoalType, _ source: MetricSource, _ value: Double, kind: String? = nil, at time: Date? = nil, id: String = UUID().uuidString) -> Metric {
        Metric(id: id, ownerId: "u", date: day, type: type, source: source, value: value,
               recordedAt: time ?? at(12), detail: kind.map { [MetricKind.key: $0] })
    }

    @Test func stepsPendingThenMissedAfterMidnight() {
        let goal = Goal(ownerId: "u", type: .steps, target: 10_000)
        let metrics = [metric(.steps, .healthKit, 4_000, kind: MetricKind.hourlySteps),
                       metric(.steps, .healthKit, 3_000, kind: MetricKind.hourlySteps)]
        #expect(GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(20), calendar: calendar).status == .pending)
        let final = GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(1, dayOffset: 1), calendar: calendar)
        #expect(final.status == .missed)
        #expect(final.value == 7_000)
    }

    @Test func workoutMeasures() {
        var goal = Goal(ownerId: "u", type: .workout, target: 30, workoutMeasure: .longestWorkout)
        let metrics = [metric(.workout, .healthKit, 20, kind: MetricKind.workout),
                       metric(.workout, .healthKit, 35, kind: MetricKind.exerciseMinutes)]
        #expect(GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(20), calendar: calendar).status == .pending)
        goal.workoutMeasure = .exerciseMinutes
        #expect(GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(20), calendar: calendar).status == .hit)
    }

    @Test func workoutCountIgnoresWalks() {
        let goal = Goal(ownerId: "u", type: .workout, target: 1, workoutMeasure: .workoutCount)
        func workout(_ type: Int, _ name: String, minutes: Double = 5) -> Metric {
            Metric(id: UUID().uuidString, ownerId: "u", date: day, type: .workout, source: .healthKit, value: minutes,
                   recordedAt: at(12), detail: [MetricKind.key: MetricKind.workout, "activityType": String(type), "activity": name])
        }
        let walk = workout(52, "Walking", minutes: 60)
        let run = workout(37, "Running")
        #expect(GoalEvaluator.evaluate(goal, metrics: [walk], day: day, now: at(20), calendar: calendar).status == .pending)
        let summary = GoalEvaluator.evaluate(goal, metrics: [walk, run], day: day, now: at(20), calendar: calendar)
        #expect(summary.status == .hit && summary.value == 1)
        #expect(GoalFormat.value(summary, goal: goal) == "1 / 1 workout")

        var two = goal
        two.target = 2
        #expect(GoalEvaluator.evaluate(two, metrics: [walk, run], day: day, now: at(1, dayOffset: 1), calendar: calendar).status == .missed)
    }

    @Test func workoutCountFallsBackToActivityName() {
        let goal = Goal(ownerId: "u", type: .workout, target: 1, workoutMeasure: .workoutCount)
        let oldWalk = Metric(id: "w", ownerId: "u", date: day, type: .workout, source: .healthKit, value: 30,
                             detail: [MetricKind.key: MetricKind.workout, "activity": "Walking"])
        #expect(GoalEvaluator.evaluate(goal, metrics: [oldWalk], day: day, now: at(20), calendar: calendar).status == .pending)
    }

    @Test func screenTimeRangeAndSnapshotOverride() {
        let goal = Goal(ownerId: "u", type: .screenTime, target: 120)
        var metrics = [metric(.screenTime, .threshold, 0, kind: MetricKind.monitoring),
                       metric(.screenTime, .threshold, 90), metric(.screenTime, .threshold, 60)]
        let midday = GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(15), calendar: calendar)
        #expect(midday.status == .pending)
        #expect(midday.confidence == .range)
        #expect(midday.value == 90 && midday.upperValue == 120)

        let endOfDay = GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(0, dayOffset: 1), calendar: calendar)
        #expect(endOfDay.status == .hit)

        metrics.append(metric(.screenTime, .threshold, 120))
        #expect(GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(21), calendar: calendar).status == .missed)

        metrics.append(metric(.screenTime, .snapshot, 118, at: at(22)))
        let snap = GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(7, dayOffset: 1), calendar: calendar)
        #expect(snap.status == .hit && snap.confidence == .exact && snap.value == 118)
    }

    @Test func screenTimeWithoutMonitoringIsPending() {
        let goal = Goal(ownerId: "u", type: .screenTime, target: 120)
        #expect(GoalEvaluator.evaluate(goal, metrics: [], day: day, now: at(1, dayOffset: 1), calendar: calendar).status == .pending)
    }

    @Test func pickupsSelfReportFallback() {
        let goal = Goal(ownerId: "u", type: .pickups, target: 60)
        let answer = metric(.pickups, .manual, 1, kind: MetricKind.pickupsSelfReport)
        let summary = GoalEvaluator.evaluate(goal, metrics: [answer], day: day, now: at(22), calendar: calendar)
        #expect(summary.status == .hit && summary.confidence == .selfReported)
    }

    @Test func partialDaySnapshotIsNotARecapQuestion() {
        let goal = Goal(ownerId: "u", type: .pickups, target: 60)
        let snapshot = metric(.pickups, .snapshot, 19, at: at(12))
        let summary = GoalEvaluator.evaluate(goal, metrics: [snapshot], day: day, now: at(21), calendar: calendar)
        #expect(summary.status == .pending)
        #expect(GoalEvaluator.questions(for: [summary]).isEmpty)

        let unmeasured = GoalEvaluator.evaluate(goal, metrics: [], day: day, now: at(21), calendar: calendar)
        #expect(GoalEvaluator.questions(for: [unmeasured]) == [.pickups])
    }

    @Test func overeatingLatestAnswerWins() {
        let goal = Goal(ownerId: "u", type: .overeating, target: 0)
        let metrics = [metric(.overeating, .manual, 1, at: at(21)), metric(.overeating, .manual, 0, at: at(22))]
        #expect(GoalEvaluator.evaluate(goal, metrics: metrics, day: day, now: at(23), calendar: calendar).status == .hit)
    }

    @Test func wakeupWithinFiveMinutes() {
        let goal = Goal(ownerId: "u", type: .wakeup, target: 7 * 60, days: .weekdays)
        let onTime = GoalEvaluator.evaluate(goal, metrics: [metric(.wakeup, .healthKit, 7 * 60 + 5)], day: day, now: at(9), calendar: calendar)
        #expect(onTime.status == .hit)
        let early = GoalEvaluator.evaluate(goal, metrics: [metric(.wakeup, .healthKit, 5 * 60)], day: day, now: at(9), calendar: calendar)
        #expect(early.status == .hit)
        let late = GoalEvaluator.evaluate(goal, metrics: [metric(.wakeup, .healthKit, 7 * 60 + 6)], day: day, now: at(9), calendar: calendar)
        #expect(late.status == .missed)
    }

    @Test func wakeupOffOnUnselectedDays() {
        let goal = Goal(ownerId: "u", type: .wakeup, target: 7 * 60, days: Weekdays(weekday: 7)) // Saturday only
        #expect(GoalEvaluator.evaluate(goal, metrics: [], day: day, now: at(9), calendar: calendar).status == .off)
    }

    @Test func streakSkipsOffDays() {
        let goal = Goal(id: "g", ownerId: "u", type: .wakeup, target: 420)
        func s(_ offset: Int, _ status: DayStatus) -> DaySummary {
            DaySummary(ownerId: "u", date: day.adding(days: offset, calendar: calendar), goalId: goal.id, goalType: .wakeup, status: status, value: nil, confidence: .exact)
        }
        let summaries = [s(0, .pending), s(-1, .hit), s(-2, .off), s(-3, .hit), s(-4, .missed)]
        #expect(Streaks.current(goalId: "g", summaries: summaries, today: day, calendar: calendar) == 2)
    }
}

struct WakeupDetectorTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    let day = DayKey(rawValue: "2026-09-28")!

    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: day.start(calendar: calendar))!
    }

    @Test func usesLatestWakeAfterBriefAwakening() {
        let samples = [
            SleepInterval(start: at(-1, -30), end: at(3)),   // 10:30pm – 3am
            SleepInterval(start: at(3, 10), end: at(6, 50)), // back asleep after a short wake
            SleepInterval(start: at(7, 5), end: at(7, 32)),  // dozed again after the alarm
        ]
        #expect(WakeupDetector.wakeTime(from: samples, on: day, calendar: calendar) == at(7, 32))
    }

    @Test func ignoresAfternoonNap() {
        let samples = [
            SleepInterval(start: at(-1), end: at(6, 45)),
            SleepInterval(start: at(13), end: at(13, 40)),
        ]
        #expect(WakeupDetector.wakeTime(from: samples, on: day, calendar: calendar) == at(6, 45))
    }

    @Test func noSleepMeansNoWakeTime() {
        #expect(WakeupDetector.wakeTime(from: [], on: day, calendar: calendar) == nil)
    }

    @Test func minutesAfterMidnight() {
        #expect(WakeupDetector.minutesAfterMidnight(at(7, 3), on: day, calendar: calendar) == 423)
    }
}
