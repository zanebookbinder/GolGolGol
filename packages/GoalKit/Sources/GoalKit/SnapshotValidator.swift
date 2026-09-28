import Foundation

public enum SnapshotValidationError: Error, Equatable, LocalizedError {
    case wentBackward(type: GoalType, previous: Int, new: Int)
    case implausible(GoalType, Int)

    public var errorDescription: String? {
        switch self {
        case .wentBackward(let type, let previous, let new):
            "\(type.title) went backward from \(previous) to \(new); probably an OCR misread."
        case .implausible(let type, let value):
            "\(type.title) of \(value) isn't possible in one day."
        }
    }
}

public enum SnapshotValidator {
    /// Screen time and pickups only grow during a day, so a lower value than an earlier snapshot of
    /// the same day is a misread.
    public static func validate(_ reading: SnapshotReading, day: DayKey, existing: [Metric]) throws {
        guard reading.screenTimeMinutes <= 24 * 60 else { throw SnapshotValidationError.implausible(.screenTime, reading.screenTimeMinutes) }
        if let pickups = reading.pickups, pickups > 2_000 { throw SnapshotValidationError.implausible(.pickups, pickups) }

        let earlier = existing.filter { $0.date == day && $0.source == .snapshot }
        if let previous = earlier.filter({ $0.type == .screenTime }).map(\.value).max(), Double(reading.screenTimeMinutes) < previous {
            throw SnapshotValidationError.wentBackward(type: .screenTime, previous: Int(previous), new: reading.screenTimeMinutes)
        }
        if let pickups = reading.pickups,
           let previous = earlier.filter({ $0.type == .pickups }).map(\.value).max(), Double(pickups) < previous {
            throw SnapshotValidationError.wentBackward(type: .pickups, previous: Int(previous), new: pickups)
        }
    }

    /// The Metrics a snapshot produces.
    public static func metrics(for reading: SnapshotReading, day: DayKey, ownerId: String, at date: Date = .now) -> [Metric] {
        let stamp = Int(date.timeIntervalSince1970)
        var metrics = [Metric(id: "snapshot:\(stamp)", ownerId: ownerId, date: day, type: .screenTime, source: .snapshot,
                              value: Double(reading.screenTimeMinutes), recordedAt: date)]
        if let pickups = reading.pickups {
            metrics.append(Metric(id: "snapshot:\(stamp)", ownerId: ownerId, date: day, type: .pickups, source: .snapshot,
                                  value: Double(pickups), recordedAt: date))
        }
        return metrics
    }
}
