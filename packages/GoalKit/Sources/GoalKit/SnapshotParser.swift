import Foundation

/// Numbers read from an OCR'd screenshot of the Snapshot report view.
public struct SnapshotReading: Equatable, Sendable {
    public var screenTimeMinutes: Int
    public var pickups: Int?
    /// The report's day as `yyyy-MM-dd`, when the date line was readable.
    public var day: String?

    public init(screenTimeMinutes: Int, pickups: Int?, day: String?) {
        self.screenTimeMinutes = screenTimeMinutes
        self.pickups = pickups
        self.day = day
    }
}

public enum SnapshotParseError: Error, Equatable, CustomStringConvertible {
    case screenTimeNotFound

    public var description: String {
        switch self {
        case .screenTimeNotFound: "Couldn't find a screen time value in the text."
        }
    }
}

/// Parses the text that Shortcuts' "Extract Text from Image" produces from the Snapshot screen.
///
/// The report extension renders these labels verbatim, one per line, each followed by its value:
///
///     DATE 2026-09-28
///     SCREEN TIME
///     134 min
///     PICKUPS
///     87
///
/// The parser also accepts "2h 14m"-style durations and values on the same line as their label,
/// so it keeps working if the layout changes or OCR merges lines.
public enum SnapshotParser {
    public static let dateLabel = "DATE"
    public static let screenTimeLabel = "SCREEN TIME"
    public static let pickupsLabel = "PICKUPS"

    /// Label fragments used to find a value's line and to stop scanning at the next label.
    private static let labelKeys = ["SCREEN", "PICKUP", dateLabel]

    public static func parse(_ text: String) throws -> SnapshotReading {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let minutes = value(after: "SCREEN", in: lines, parse: durationMinutes) else {
            throw SnapshotParseError.screenTimeNotFound
        }
        return SnapshotReading(
            screenTimeMinutes: minutes,
            pickups: value(after: "PICKUP", in: lines, parse: integer),
            day: lines.lazy.compactMap(isoDay).first
        )
    }

    /// Returns the first value parsed from the text after `key` on its line, or from the next two
    /// lines, stopping early at a line that holds another label.
    static func value(after key: String, in lines: [String], parse: (String) -> Int?) -> Int? {
        guard let index = lines.firstIndex(where: { $0.uppercased().contains(key) }) else { return nil }

        let rest = lines[index].uppercased().components(separatedBy: key).dropFirst().joined(separator: key)
        if let value = parse(rest) { return value }

        for line in lines.dropFirst(index + 1).prefix(2) {
            if labelKeys.contains(where: line.uppercased().contains) { break }
            if let value = parse(line) { return value }
        }
        return nil
    }

    /// Minutes from "2h 14m", "2 hr 14 min", "134 min", or a bare "134".
    static func durationMinutes(_ text: String) -> Int? {
        let s = normalizedDigits(text).uppercased()
        if let m = s.firstMatch(of: #/(\d+)\s*H(?:OURS?|RS?)?(?:\s*(\d+)\s*M)?/#) {
            return Int(m.1)! * 60 + (m.2.flatMap { Int($0) } ?? 0)
        }
        if let m = s.firstMatch(of: #/(\d+)\s*M/#) {
            return Int(m.1)
        }
        return integer(s)
    }

    /// The first whole number in the text.
    static func integer(_ text: String) -> Int? {
        normalizedDigits(text).firstMatch(of: #/\d+/#).flatMap { Int($0.output) }
    }

    static func isoDay(_ text: String) -> String? {
        text.firstMatch(of: #/\d{4}-\d{2}-\d{2}/#).map { String($0.output) }
    }

    /// OCR sometimes reads 0 as O and 1 as I, l, or |. Only fixes words that contain a digit and are
    /// otherwise made of those look-alikes, so ordinary words are left alone.
    static func normalizedDigits(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            guard word.wholeMatch(of: #/[0-9OoIl|]+/#) != nil, word.contains(where: \.isNumber) else {
                return String(word)
            }
            return String(word.map { c in
                switch c {
                case "O", "o": "0"
                case "I", "l", "|": "1"
                default: c
                }
            })
        }.joined(separator: " ")
    }
}
