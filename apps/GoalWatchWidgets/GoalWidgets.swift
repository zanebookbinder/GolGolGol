import GoalKit
import SwiftUI
import WidgetKit

struct GoalEntry: TimelineEntry {
    var date: Date
    var goals: [Goal]
    var summaries: [DaySummary]
    var isRecapTime: Bool
    var relevance: TimelineEntryRelevance?

    var applicable: [DaySummary] { summaries.filter { $0.status != .off } }
    var hits: Int { applicable.filter { $0.status == .hit }.count }

    /// The pending at-least goal closest to done, else any pending goal.
    var nextClosest: (Goal, DaySummary?)? {
        let pending = goals.compactMap { goal -> (Goal, DaySummary?)? in
            let summary = summaries.first { $0.goalId == goal.id }
            return summary?.status == .pending || summary == nil ? (goal, summary) : nil
        }
        return pending.filter { $0.0.direction == .atLeast }.max { GoalFormat.progress($0.1, goal: $0.0) < GoalFormat.progress($1.1, goal: $1.0) }
            ?? pending.first
    }

    static let placeholder: GoalEntry = {
        let goals = Goal.defaults(ownerId: "preview")
        let day = DayKey.today()
        let summaries = goals.enumerated().map { index, goal in
            DaySummary(ownerId: "preview", date: day, goalId: goal.id, goalType: goal.type,
                       status: index < 3 ? .hit : .pending, value: goal.type == .steps ? 7_400 : nil, confidence: .exact)
        }
        return GoalEntry(date: .now, goals: goals, summaries: summaries, isRecapTime: false)
    }()
}

/// Reads the Watch app's store from the App Group. Refreshes every 30 minutes, and whenever the app
/// reloads timelines after a new Metric.
struct GoalProvider: TimelineProvider {
    func placeholder(in context: Context) -> GoalEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (GoalEntry) -> Void) {
        completion(context.isPreview ? .placeholder : entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalEntry>) -> Void) {
        let now = Date.now
        let entries = (0..<4).map { entry(at: now.addingTimeInterval(Double($0) * 30 * 60)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(2 * 60 * 60))))
    }

    private func entry(at date: Date) -> GoalEntry {
        let data = LocalStore.read(from: AppGroup.storeURL) ?? StoreData()
        let day = DayKey(date)
        let goals = data.activeGoals
        let summaries = goals.compactMap { data.summary(goalId: $0.id, day: day) }

        // Smart Stack: most relevant from 30 minutes before the recap to an hour after.
        let recapStart = Calendar.current.date(byAdding: .minute, value: data.preferences.recapMinutes - 30, to: day.start())!
        let isRecapTime = date >= recapStart && date < recapStart.addingTimeInterval(90 * 60) 
            && !GoalEvaluator.questions(for: data.summaries(for: day)).isEmpty
        return GoalEntry(date: date, goals: goals, summaries: summaries, isRecapTime: isRecapTime,
                         relevance: TimelineEntryRelevance(score: isRecapTime ? 100 : 10))
    }
}

struct GoalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: GoalEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(entry.hits), in: 0...Double(max(entry.applicable.count, 1))) {
                Image(systemName: "checkmark")
            } currentValueLabel: {
                Text("\(entry.hits)/\(entry.applicable.count)")
            }
            .gaugeStyle(.accessoryCircular)
            .widgetURL(URL(string: "goaltracker://today"))

        case .accessoryInline:
            Text("\(entry.hits)/\(entry.applicable.count) goals")

        case .accessoryCorner:
            Text("\(entry.hits)/\(entry.applicable.count)")
                .widgetLabel { Gauge(value: Double(entry.hits), in: 0...Double(max(entry.applicable.count, 1))) {} }

        default:
            rectangular
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        if entry.isRecapTime {
            VStack(alignment: .leading, spacing: 2) {
                Label("Recap", systemImage: "moon.stars").font(.headline)
                Text("\(entry.hits) of \(entry.applicable.count) completed")
                Text("Tap to review your day").font(.caption2).foregroundStyle(.secondary)
            }
            .widgetURL(URL(string: "goaltracker://recap"))
        } else if let next = entry.nextClosest {
            let (goal, summary) = next
            VStack(alignment: .leading, spacing: 3) {
                Label(goal.type.title, systemImage: goal.type.symbol).font(.headline)
                Text(GoalFormat.value(summary, goal: goal)).font(.caption)
                ProgressView(value: GoalFormat.progress(summary, goal: goal))
                    .tint(.blue)
            }
            .widgetURL(URL(string: "goaltracker://today"))
        } else {
            VStack(alignment: .leading) {
                Label("All completed", systemImage: "checkmark.circle").font(.headline)
                Text("\(entry.hits) of \(entry.applicable.count) goals completed")
            }
        }
    }
}

struct GoalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Goals", provider: GoalProvider()) { entry in
            GoalWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("GolGolGol!!!")
        .description("Goals hit today, the next one to finish, and the recap at night.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

/// A small ring for one goal, in the apps' status colors: blue and filling while in progress, solid
/// green when completed, solid red with an ✕ when missed.
struct MiniRing: View {
    var goal: Goal
    var summary: DaySummary?

    var body: some View {
        let status = summary?.status ?? .pending
        ZStack {
            switch status {
            case .hit, .missed:
                Circle().fill(status == .hit ? Color.green : Color.red)
                Image(systemName: goal.type.symbol)
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                if status == .missed {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .light)).foregroundStyle(.white.opacity(0.35))
                }
            case .pending:
                Circle().stroke(Color.blue.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: GoalFormat.progress(summary, goal: goal))
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: goal.type.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.blue)
            case .off:
                Circle().stroke(Color.gray.opacity(0.3), lineWidth: 3)
                Image(systemName: goal.type.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.gray)
            }
        }
        .widgetAccentable()
    }
}

/// All goals at once, for the Smart Stack: today's count, then each goal's ring with its value.
struct AllGoalsWidgetView: View {
    var entry: GoalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(entry.hits)/\(entry.applicable.count) completed")
                .font(.system(size: 13, weight: .semibold))
            Grid(horizontalSpacing: 6, verticalSpacing: 3) {
                ForEach(rows, id: \.first?.id) { row in
                    GridRow {
                        ForEach(row) { goal in
                            let summary = entry.summaries.first { $0.goalId == goal.id }
                            HStack(spacing: 3) {
                                MiniRing(goal: goal, summary: summary)
                                    .frame(width: 16, height: 16)
                                Text(shortValue(goal, summary))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "goaltracker://today"))
    }

    /// Two rows of three.
    private var rows: [[Goal]] {
        stride(from: 0, to: entry.goals.count, by: 3).map { Array(entry.goals[$0..<min($0 + 3, entry.goals.count)]) }
    }

    /// A few characters per goal: "8.2k", "20m", "1h45", "23", "6:12", or a check or cross.
    private func shortValue(_ goal: Goal, _ summary: DaySummary?) -> String {
        guard let summary, summary.status != .off else { return summary?.status == .off ? "off" : "–" }
        let value = summary.value
        switch goal.type {
        case .steps:
            let steps = value ?? 0
            return steps >= 1000 ? String(format: "%.1fk", steps / 1000) : "\(Int(steps))"
        case .workout:
            switch goal.workoutMeasure ?? .longestWorkout {
            case .workoutCount: return "\(Int(value ?? 0))/\(Int(goal.target))"
            case .longestWorkout: return "\((value ?? 0) >= goal.target || summary.status == .hit ? 1 : 0)/1"
            case .exerciseMinutes: return "\(Int(value ?? 0))m"
            }
        case .screenTime:
            return value.map { GoalFormat.duration(minutes: $0) } ?? "–"
        case .pickups:
            return value.map { "\(Int($0))" } ?? statusMark(summary)
        case .wakeup:
            return value.map { GoalFormat.clock(minutesAfterMidnight: $0).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") } ?? statusMark(summary)
        case .overeating, .phoneBeforeBed:
            return statusMark(summary)
        }
    }

    private func statusMark(_ summary: DaySummary) -> String {
        switch summary.status {
        case .hit: "✓"
        case .missed: "✗"
        default: "–"
        }
    }
}

/// Smart Stack relevance: always somewhat relevant during the day, more so in the evening when
/// there's still time to finish goals.
struct AllGoalsProvider: TimelineProvider {
    private let base = GoalProvider()

    func placeholder(in context: Context) -> GoalEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (GoalEntry) -> Void) {
        base.getSnapshot(in: context, completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalEntry>) -> Void) {
        base.getTimeline(in: context) { timeline in
            let entries = timeline.entries.map { entry -> GoalEntry in
                var entry = entry
                let hour = Calendar.current.component(.hour, from: entry.date)
                let allDone = entry.hits == entry.applicable.count && !entry.applicable.isEmpty
                entry.relevance = TimelineEntryRelevance(score: allDone ? 20 : (hour >= 17 ? 80 : 50))
                return entry
            }
            completion(Timeline(entries: entries, policy: timeline.policy))
        }
    }
}

struct AllGoalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AllGoals", provider: AllGoalsProvider()) { entry in
            AllGoalsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("All goals")
        .description("Every goal's progress today, for the Smart Stack.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct GoalWidgetBundle: WidgetBundle {
    var body: some Widget {
        AllGoalsWidget()
        GoalsWidget()
    }
}
