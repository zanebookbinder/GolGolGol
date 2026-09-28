/// The DeviceActivity threshold events registered for a day's screen time.
public enum ThresholdLadder {
    /// How long before the limit the "30 minutes left" reminder fires.
    public static let warningMinutes = 30

    /// Coarse steps up to the goal, a warning step `warningMinutes` before it, the goal itself, then
    /// fine steps past it.
    ///
    /// With a 105-minute goal: 30, 60, 75 (warning), 90, 105, 120, 135, … up to `goal + overshoot`.
    public static func minutes(goal: Int, overshoot: Int = 240, coarseStep: Int = 30, fineStep: Int = 15) -> [Int] {
        precondition(goal > 0 && coarseStep > 0 && fineStep > 0)
        var ladder = Set(stride(from: coarseStep, to: goal, by: coarseStep))
        if goal > warningMinutes { ladder.insert(goal - warningMinutes) }
        ladder.insert(goal)
        ladder.formUnion(stride(from: goal + fineStep, through: goal + overshoot, by: fineStep))
        return ladder.sorted()
    }
}

/// What the threshold events crossed so far say about the day's screen time.
public struct ScreenTimeRange: Equatable, Sendable {
    /// The highest threshold crossed, or 0 if none has been.
    public var lowerMinutes: Int
    /// The next threshold not yet crossed; nil once usage is past the top of the ladder.
    public var upperMinutes: Int?

    public init(lowerMinutes: Int, upperMinutes: Int?) {
        self.lowerMinutes = lowerMinutes
        self.upperMinutes = upperMinutes
    }

    public init(crossed: some Sequence<Int>, ladder: [Int]) {
        let lower = crossed.max() ?? 0
        self.init(lowerMinutes: lower, upperMinutes: ladder.sorted().first { $0 > lower })
    }
}
