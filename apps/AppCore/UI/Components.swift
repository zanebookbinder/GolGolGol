import GoalKit
import SwiftUI

extension DayStatus {
    var color: Color {
        switch self {
        case .hit: .green
        case .missed: .red
        case .pending: .gray
        case .off: .gray.opacity(0.25)
        }
    }

    var label: String {
        switch self {
        case .hit: "Completed"
        case .missed: "Missed"
        case .pending: "Pending"
        case .off: "Off"
        }
    }
}

extension GoalType {
    /// Each goal's color, used everywhere it appears (rings, grids, charts, widgets). Red is kept for misses.
    var color: Color {
        switch self {
        case .steps: .blue
        case .workout: .green
        case .screenTime: .purple
        case .pickups: .orange
        case .overeating: .pink
        case .wakeup: .yellow
        }
    }
}

/// Progress ring in the goal's color with its symbol in the middle. Completed fills the ring;
/// missed turns it red; off is grey.
struct GoalRing: View {
    var goal: Goal
    var summary: DaySummary?
    var size: CGFloat = 36
    var lineWidth: CGFloat = 4

    private var status: DayStatus { summary?.status ?? .pending }

    private var tint: Color {
        switch status {
        case .missed: .red
        case .off: .gray
        default: goal.type.color
        }
    }

    var body: some View {
        ZStack {
            if status == .hit {
                Circle().fill(tint)
                Image(systemName: goal.type.symbol)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.black)
            } else {
                Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: GoalFormat.progress(summary, goal: goal))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: goal.type.symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("\(goal.type.title): \(status.label)")
    }
}

/// One goal on one day in the History grids: filled in the goal's color when completed, red when
/// missed, an outline while pending, faint when off or in the future.
struct StatusDot: View {
    var status: DayStatus?
    var color: Color = .gray
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(fill)
            .overlay {
                if status == .pending { Circle().stroke(color.opacity(0.6), lineWidth: 1) }
            }
            .frame(width: size, height: size)
    }

    private var fill: Color {
        switch status {
        case .hit: color
        case .missed: .red.opacity(0.8)
        case .pending: .clear
        case .off: .gray.opacity(0.2)
        case nil: .gray.opacity(0.12)
        }
    }
}

/// One goal's row: ring, title, and today's value.
struct GoalRowContent: View {
    var goal: Goal
    var summary: DaySummary?

    var body: some View {
        HStack(spacing: 10) {
            GoalRing(goal: goal, summary: summary)
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.type.title).font(.headline)
                Text(GoalFormat.value(summary, goal: goal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A stepper whose label stays readable on the Watch, where Stepper draws its label very large:
/// the value at a normal size with a small caption (unit) beneath. On iPhone it's a regular row.
struct CompactStepper: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    /// The value as shown, e.g. "10,000" or "2h".
    var text: String
    /// Small text under the value on the Watch, after it on the iPhone, e.g. "steps" or "at most".
    var caption: String

    var body: some View {
        #if os(watchOS)
        Stepper(value: $value, in: range, step: step) {
            VStack(spacing: 0) {
                Text(text)
                    .font(.title3.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        #else
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(text).monospacedDigit()
                Text(caption).foregroundStyle(.secondary)
            }
        }
        #endif
    }
}

/// Weekday initials in calendar order (respecting the locale's first weekday).
enum WeekdaySymbols {
    static var ordered: [(weekday: Int, symbol: String)] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        return (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return (weekday, symbols[weekday - 1])
        }
    }
}

/// True when every goal that applied on `day` was completed (and at least one applied).
private func isPerfect(_ goals: [Goal], _ day: DayKey, _ summary: (Goal, DayKey) -> DaySummary?) -> Bool {
    let statuses = goals.compactMap { summary($0, day)?.status }.filter { $0 != .off }
    return !statuses.isEmpty && statuses.count == goals.filter { summary($0, day)?.status != .off }.count
        && statuses.allSatisfy { $0 == .hit }
}

/// A 7 × goals grid for one week: a row per goal (labeled with its icon in its color), a column per
/// day. Today's column letter is highlighted and a star marks perfect days.
struct WeekGrid: View {
    var goals: [Goal]
    var days: [DayKey]
    var summary: (Goal, DayKey) -> DaySummary?
    var dotSize: CGFloat = 9
    /// Tapping a day's letter opens it.
    var onSelect: ((DayKey) -> Void)?

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(days, id: \.self) { day in
                    Button {
                        onSelect?(day)
                    } label: {
                        Text(WeekdaySymbols.ordered.first { $0.weekday == day.weekday() }?.symbol ?? "")
                            .font(.caption2.weight(day == .today() ? .bold : .regular))
                            .foregroundStyle(day == .today() ? Color.black : .secondary)
                            .frame(minWidth: dotSize + 6, minHeight: dotSize + 6)
                            .background(day == .today() ? Color.white : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(onSelect == nil || day > .today())
                }
            }
            ForEach(goals) { goal in
                GridRow {
                    Image(systemName: goal.type.symbol).font(.caption2).foregroundStyle(goal.type.color)
                    ForEach(days, id: \.self) { day in
                        StatusDot(status: day > .today() ? nil : summary(goal, day)?.status, color: goal.type.color, size: dotSize)
                    }
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(days, id: \.self) { day in
                    Image(systemName: "star.fill")
                        .font(.system(size: dotSize))
                        .foregroundStyle(.yellow)
                        .opacity(day <= .today() && isPerfect(goals, day, summary) ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A month calendar with one dot per goal per day, in the goals' colors. Perfect days get a gold
/// circle behind the date; today's date is outlined.
struct MonthGrid: View {
    var goals: [Goal]
    var month: [DayKey]
    var summary: (Goal, DayKey) -> DaySummary?
    var dotSize: CGFloat = 3
    var onSelect: ((DayKey) -> Void)?

    private var leadingBlanks: Int {
        guard let first = month.first else { return 0 }
        return (first.weekday() - Calendar.current.firstWeekday + 7) % 7
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(WeekdaySymbols.ordered, id: \.weekday) { item in
                Text(item.symbol).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 1) }
            ForEach(month, id: \.self) { day in
                Button {
                    onSelect?(day)
                } label: {
                    VStack(spacing: 1) {
                        Text(day.rawValue.suffix(2).trimmingPrefix("0"))
                            .font(.system(size: 10, weight: day == .today() ? .bold : .regular))
                            .foregroundStyle(perfect(day) ? Color.black : .primary)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(perfect(day) ? Color.yellow : .clear, in: Circle())
                            .overlay { if day == .today() { Circle().stroke(Color.white, lineWidth: 1) } }
                        dots(for: day)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(onSelect == nil || day > .today())
            }
        }
    }

    private func perfect(_ day: DayKey) -> Bool {
        day <= .today() && isPerfect(goals, day, summary)
    }

    private func dots(for day: DayKey) -> some View {
        let columns = Array(repeating: GridItem(.fixed(dotSize), spacing: 1), count: 3)
        return LazyVGrid(columns: columns, spacing: 1) {
            ForEach(goals) { goal in
                StatusDot(status: day > .today() ? nil : summary(goal, day)?.status, color: goal.type.color, size: dotSize)
            }
        }
        .frame(width: dotSize * 3 + 2)
    }
}
