import Foundation
import Testing
@testable import GoalKit

struct BedtimeTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    let night = DayKey(rawValue: "2026-09-28")!
    let goal = Goal(ownerId: "u", type: .phoneBeforeBed, target: 30)

    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: night.start(calendar: calendar))!
    }

    func evaluate(_ metrics: [Metric], now: Date? = nil) -> DaySummary {
        GoalEvaluator.evaluate(goal, metrics: metrics, day: night, now: now ?? at(24 + 9), calendar: calendar)
    }

    var marker: Metric { Bedtime.monitoringMarker(at: at(21), ownerId: "u", calendar: calendar) }
    func use(_ threshold: Int, _ hour: Int, _ minute: Int) -> Metric {
        Bedtime.crossing(threshold: threshold, at: at(hour, minute), ownerId: "u", calendar: calendar)
    }
    func onset(_ hour: Int, _ minute: Int) -> Metric {
        Bedtime.onset(at(hour, minute), night: night, ownerId: "u", calendar: calendar)
    }

    @Test func useWellBeforeBedIsFine() {
        // Phone 9:30–9:35, asleep 10:30: the 10:00–10:30 window is clear.
        let s = evaluate([marker, use(2, 21, 32), use(4, 21, 34), onset(22, 30)])
        #expect(s.status == .hit)
        #expect(GoalFormat.value(s, goal: goal) == "Asleep 10:30\u{202F}PM · last phone 9:34\u{202F}PM")
    }

    @Test func useInTheLast30MinutesIsAMiss() {
        let s = evaluate([marker, use(2, 22, 15), onset(22, 30)])
        #expect(s.status == .missed && s.upperValue == Double(22 * 60 + 15))
    }

    @Test func afterMidnightBelongsToTheEvening() {
        let late = use(2, 24, 20) // 12:20am
        #expect(late.date == night)
        let s = evaluate([marker, late, onset(24, 40)]) // asleep 12:40am
        #expect(s.status == .missed)
    }

    @Test func useAfterFallingAsleepIsIgnored() {
        let s = evaluate([marker, use(2, 21, 10), onset(22, 30), use(4, 25, 0)]) // 1am, woke in the night
        #expect(s.status == .hit && s.upperValue == Double(21 * 60 + 10))
    }

    @Test func phoneOffAllEveningIsUnknownNotHit() {
        let s = evaluate([onset(22, 30)])
        #expect(s.status == .pending)
        #expect(GoalEvaluator.questions(for: [evaluate([onset(22, 30)], now: at(24 + 15))]) == [.phoneBeforeBed])
    }

    @Test func noSleepDataWaitsThenAsks() {
        #expect(GoalEvaluator.questions(for: [evaluate([marker], now: at(24 + 9))]).isEmpty)
        #expect(GoalEvaluator.questions(for: [evaluate([marker], now: at(24 + 15))]) == [.phoneBeforeBed])
    }

    @Test func handCorrectionsWin() {
        let wrongOnset = Metric(id: Bedtime.onsetEditId(night), ownerId: "u", date: night, type: .phoneBeforeBed, source: .manual,
                                value: Double(23 * 60 + 30), detail: [MetricKind.key: MetricKind.sleepOnsetEdit])
        // The Watch thought 10:30pm (phone at 10:15 = miss); really asleep 11:30pm: fine.
        let s = evaluate([marker, use(2, 22, 15), onset(22, 30), wrongOnset])
        #expect(s.status == .hit && s.confidence == .manual)

        let noUse = Metric(id: Bedtime.lastUseEditId(night), ownerId: "u", date: night, type: .phoneBeforeBed, source: .manual,
                           value: -1, detail: [MetricKind.key: MetricKind.lastUseEdit])
        let s2 = evaluate([use(2, 22, 15), onset(22, 30), noUse])
        #expect(s2.status == .hit && s2.upperValue == nil)
    }

    @Test func sleepOnsetIsTheMainSessionStart() {
        let morning = night.adding(days: 1, calendar: calendar)
        let samples = [SleepInterval(start: at(22, 50), end: at(26)), SleepInterval(start: at(26, 20), end: at(30, 30))]
        #expect(WakeupDetector.sleepOnset(from: samples, endingOn: morning, calendar: calendar) == at(22, 50))
    }
}
