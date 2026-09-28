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
                    .tint(goal.direction == .atLeast ? .blue : .orange)
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

extension GoalType {
    /// Same colors as the apps (see AppCore Components).
    var widgetColor: Color {
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

/// A small ring for one goal: fills in its color as it progresses, solid when completed, red if missed.
struct MiniRing: View {
    var goal: Goal
    var summary: DaySummary?

    var body: some View {
        let status = summary?.status ?? .pending
        let color: Color = status == .missed ? .red : (status == .off ? .gray : goal.type.widgetColor)
        ZStack {
            if status == .hit {
                Circle().fill(color)
                Image(systemName: goal.type.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
            } else {
                Circle().stroke(color.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: GoalFormat.progress(summary, goal: goal))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: goal.type.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            }
        }
        .widgetAccentable()
    }
}

/// All goals at once: a ring per goal and today's count.
struct AllGoalsWidgetView: View {
    var entry: GoalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(entry.hits)/\(entry.applicable.count) completed")
                .font(.headline)
            HStack(spacing: 4) {
                ForEach(entry.goals) { goal in
                    MiniRing(goal: goal, summary: entry.summaries.first { $0.goalId == goal.id })
                        .frame(width: 22, height: 22)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "goaltracker://today"))
    }
}

struct AllGoalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AllGoals", provider: GoalProvider()) { entry in
            AllGoalsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("All goals")
        .description("A ring for each goal, showing today's progress.")
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
