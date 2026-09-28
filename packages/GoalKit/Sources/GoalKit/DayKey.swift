import Foundation

/// A local calendar day, stored as "yyyy-MM-dd". Day boundaries are local midnight in the
/// device's current time zone.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else { return nil }
        self.rawValue = rawValue
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        rawValue = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func today(calendar: Calendar = .current) -> DayKey { DayKey(.now, calendar: calendar) }

    public var description: String { rawValue }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public func start(calendar: Calendar = .current) -> Date {
        let parts = rawValue.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    public func end(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: start(calendar: calendar))!
    }

    public func adding(days: Int, calendar: Calendar = .current) -> DayKey {
        DayKey(calendar.date(byAdding: .day, value: days, to: start(calendar: calendar))!, calendar: calendar)
    }

    public func weekday(calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: start(calendar: calendar))
    }

    /// True once local midnight at the end of this day has passed.
    public func isOver(now: Date = .now, calendar: Calendar = .current) -> Bool {
        now >= end(calendar: calendar)
    }

    /// Days from `from` through `to`, inclusive.
    public static func range(_ from: DayKey, through to: DayKey, calendar: Calendar = .current) -> [DayKey] {
        var days: [DayKey] = []
        var day = from
        while day <= to {
            days.append(day)
            day = day.adding(days: 1, calendar: calendar)
        }
        return days
    }

    /// The week (starting on the calendar's first weekday) that contains this day.
    public func week(calendar: Calendar = .current) -> [DayKey] {
        let interval = calendar.dateInterval(of: .weekOfYear, for: start(calendar: calendar))!
        let first = DayKey(interval.start, calendar: calendar)
        return (0..<7).map { first.adding(days: $0, calendar: calendar) }
    }

    /// Every day in this day's month.
    public func month(calendar: Calendar = .current) -> [DayKey] {
        let interval = calendar.dateInterval(of: .month, for: start(calendar: calendar))!
        let first = DayKey(interval.start, calendar: calendar)
        let last = DayKey(interval.end.addingTimeInterval(-1), calendar: calendar)
        return DayKey.range(first, through: last, calendar: calendar)
    }
}

extension DayKey {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = DayKey(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad day \(raw)"))
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
