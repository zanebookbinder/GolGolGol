import Testing
@testable import GoalKit

struct ThresholdLadderTests {
    @Test func matchesDesignDocExample() {
        // 1h45 goal: 30m, 1h, 1h15 (30 minutes left), 1h30, 1h45, 2h, 2h15…
        #expect(Array(ThresholdLadder.minutes(goal: 105).prefix(7)) == [30, 60, 75, 90, 105, 120, 135])
    }

    @Test func goalOnACoarseStepIsNotDuplicated() {
        #expect(ThresholdLadder.minutes(goal: 60, overshoot: 30) == [30, 60, 75, 90])
    }

    @Test func goalBelowFirstStep() {
        #expect(ThresholdLadder.minutes(goal: 20, overshoot: 15) == [20, 35])
    }

    @Test func rangeFromCrossings() {
        let ladder = ThresholdLadder.minutes(goal: 105)
        #expect(ScreenTimeRange(crossed: [30, 60, 90, 105], ladder: ladder) == ScreenTimeRange(lowerMinutes: 105, upperMinutes: 120))
        #expect(ScreenTimeRange(crossed: [], ladder: ladder) == ScreenTimeRange(lowerMinutes: 0, upperMinutes: 30))
        #expect(ScreenTimeRange(crossed: [ladder.last!], ladder: ladder).upperMinutes == nil)
    }
}
