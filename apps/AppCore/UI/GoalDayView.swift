import GoalKit
import SwiftUI

/// Whose data a screen shows: yours (editable) or a partner's (read-only).
enum Owner: Hashable {
    case me
    case partner(String)

    var isMe: Bool { self == .me }

    @MainActor func goals(_ model: AppModel) -> [Goal] {
        switch self {
        case .me: model.data.activeGoals
        case .partner(let id): model.data.partners[id]?.goals.filter(\.active) ?? []
        }
    }

    @MainActor func summary(_ model: AppModel, _ goal: Goal, _ day: DayKey) -> DaySummary? {
        switch self {
        case .me: model.data.summary(goalId: goal.id, day: day)
        case .partner(let id): model.data.partners[id]?.summaries["\(day.rawValue)#\(goal.id)"]
        }
    }

    @MainActor func summaries(_ model: AppModel) -> [DaySummary] {
        switch self {
        case .me: Array(model.data.summaries.values)
        case .partner(let id): model.data.partners[id].map { Array($0.summaries.values) } ?? []
        }
    }

    @MainActor func metrics(_ model: AppModel) -> [Metric] {
        switch self {
        case .me: Array(model.data.metrics.values)
        case .partner(let id): model.data.partners[id].map { Array($0.metrics.values) } ?? []
        }
    }

    @MainActor func name(_ model: AppModel) -> String {
        switch self {
        case .me: "Me"
        case .partner(let id): model.data.partners[id]?.name ?? "Partner"
        }
    }
}

/// The one page for a goal on a day: what happened (value, chart, workouts, readings) and, for your
/// own goals, the controls to correct it. Reached by tapping a goal on Today or on a day in History.
struct GoalDayView: View {
    @Environment(AppModel.self) private var model
    var goal: Goal
    var day: DayKey
    var owner: Owner = .me

    @State private var number: Double = 0
    @State private var numberText = ""
    @State private var confirmation: String?
    // Phone before bed: the times being corrected, in minutes after the evening's midnight.
    @State private var bedOnset: Double = 23 * 60
    @State private var bedLastUse: Double = 22 * 60
    @State private var bedUsedPhone = false

    private var summary: DaySummary? { owner.summary(model, goal, day) }
    private var dayMetrics: [Metric] {
        owner.metrics(model).filter { $0.date == day && $0.type == goal.type }.sorted { $0.recordedAt < $1.recordedAt }
    }
    private var canEdit: Bool { owner.isMe && day <= .today() && summary?.status != .off }
    /// Set by hand (an edit or a recap answer), so Reset has something to undo.
    private var isSetByHand: Bool {
        summary?.confidence == .manual || (summary?.confidence == .selfReported && summary?.status != .pending)
    }

    var body: some View {
        List {
            header
            timeline
            if canEdit {
                correction
                if isSetByHand {
                    Section {
                        Button("Reset", role: .destructive) {
                            run("Reset") {
                                await model.clearEdit(goal, on: day)
                                loadNumber()
                            }
                        }
                    } footer: {
                        Text(isMeasured ? "Goes back to the measured data." : "Goes back to unanswered.")
                    }
                }
            }
        }
        .navigationTitle(goal.type.title)
        .onAppear(perform: loadNumber)
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                GoalRing(goal: goal, summary: summary, size: 48, lineWidth: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(GoalFormat.value(summary, goal: goal)).font(.headline)
                    Text("Goal: \(GoalFormat.target(goal))").font(.caption).foregroundStyle(.secondary)
                    if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            let streak = Streaks.current(goalId: goal.id, summaries: owner.summaries(model), today: day)
            if streak > 0 {
                Label("\(streak)-day streak", systemImage: "flame").foregroundStyle(.orange)
            }
        } header: {
            Text(dayName)
        }
    }

    private var dayName: String {
        if day == .today() { return "Today" }
        if day == DayKey.today().adding(days: -1) { return "Yesterday" }
        return day.start().formatted(.dateTime.weekday(.wide).month().day())
    }

    private var note: String? {
        switch summary?.confidence {
        case .range: "Estimated from Screen Time thresholds"
        case .manual: "Set manually"
        case .selfReported where summary?.status != .pending: "Answered in the recap"
        default: nil
        }
    }

    // MARK: What happened

    @ViewBuilder
    private var timeline: some View {
        switch goal.type {
        case .workout:
            let workouts = dayMetrics.filter { $0.detail?[MetricKind.key] == MetricKind.workout }
            let exercise = dayMetrics.first { $0.detail?[MetricKind.key] == MetricKind.exerciseMinutes }
            Section("Workouts") {
                if workouts.isEmpty { Text("None logged").foregroundStyle(.secondary) }
                ForEach(workouts) { workout in
                    VStack(alignment: .leading) {
                        Text("\(workout.detail?["activity"] ?? "Workout") · \(Int(workout.value)) min")
                        Text(workoutSubtitle(workout)).font(.caption2).foregroundStyle(.secondary)
                        if !WorkoutRules.counts(workout) {
                            Text("Walks don't count toward this goal").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                if let exercise {
                    LabeledContent("Exercise minutes", value: "\(Int(exercise.value))")
                }
            }
        case .phoneBeforeBed:
            let found = Bedtime.findings(metrics: owner.metrics(model), night: day)
            Section {
                LabeledContent("Fell asleep") {
                    Text(found.sleepOnset.map { GoalFormat.clock(minutesAfterMidnight: $0) + (found.onsetEdited ? " (corrected)" : "") }
                         ?? "No sleep data yet")
                }
                LabeledContent("Last phone use") {
                    Text(lastUseText(found))
                }
            } header: {
                Text("What was found")
            } footer: {
                Text("Bedtime comes from your Sleep data. Phone use is picked up 9 PM–3 AM in 2-minute steps and can lag a few minutes; correct it below if it's wrong.")
            }
        case .wakeup:
            if let wake = dayMetrics.last(where: { $0.source == .healthKit }) {
                Section("Sleep data") {
                    LabeledContent("Woke up", value: GoalFormat.clock(minutesAfterMidnight: wake.value))
                    let late = wake.value - goal.target
                    Text(late <= 0 ? "\(Int(-late)) min early" : "\(Int(late)) min late")
                        .foregroundStyle(late <= GoalEvaluator.wakeupToleranceMinutes ? .green : .red)
                }
            } else if summary?.status == .off {
                Section { Text("No wake-up goal on \(day.start().formatted(.dateTime.weekday(.wide)))s").foregroundStyle(.secondary) }
            }
        case .steps, .screenTime, .pickups, .overeating:
            // Just the result (shown above).
            EmptyView()
        }
    }

    private func lastUseText(_ found: Bedtime.Findings) -> String {
        let suffix = found.lastUseEdited ? " (corrected)" : ""
        if let lastUse = found.lastUse { return GoalFormat.clock(minutesAfterMidnight: lastUse) + suffix }
        return found.monitored ? "None this evening" + suffix : "Not measured (phone off?)"
    }

    private func workoutSubtitle(_ workout: Metric) -> String {
        var parts: [String] = []
        if let start = workout.detail?["start"].flatMap({ try? Date($0, strategy: .iso8601) }) {
            parts.append(start.formatted(date: .omitted, time: .shortened))
        }
        if let kcal = workout.detail?["calories"] { parts.append("\(kcal) kcal") }
        if let bpm = workout.detail?["avgHeartRate"] { parts.append("\(bpm) bpm") }
        return parts.joined(separator: " · ")
    }

    // MARK: Correcting the day

    /// Measured goals go back to data on Reset; over-eating (and unmeasured answers) go back to unanswered.
    private var isMeasured: Bool {
        switch goal.type {
        case .steps, .workout, .screenTime: true
        case .pickups, .wakeup: summary?.value != nil || dayMetrics.contains { $0.source != .manual }
        case .overeating: false
        case .phoneBeforeBed: true
        }
    }

    @ViewBuilder
    private var correction: some View {
        if goal.type == .phoneBeforeBed {
            Section {
                DatePicker("Fell asleep", selection: eveningTime($bedOnset), displayedComponents: .hourAndMinute)
                Toggle("Used phone before sleep", isOn: $bedUsedPhone)
                if bedUsedPhone {
                    DatePicker("Last phone use", selection: eveningTime($bedLastUse), displayedComponents: .hourAndMinute)
                }
                Button("Save") {
                    run("Saved") {
                        await model.setBedtime(goal, night: day, sleepOnset: bedOnset, lastUse: bedUsedPhone ? bedLastUse : nil)
                    }
                }
            } header: {
                Text("Correct the times")
            } footer: {
                Text("Completed or missed follows from these times and your goal.")
            }
        } else if goal.type == .overeating {
            Section("Set the result") {
                HStack(spacing: 6) {
                    choice("Didn't over-eat", selected: summary?.status == .hit, color: .green) {
                        await model.edit(goal, on: day, hit: true)
                    }
                    choice("Did over-eat", selected: summary?.status == .missed, color: .red) {
                        await model.edit(goal, on: day, hit: false)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        } else {
            Section {
                numberInput
                Button("Save") { save() }
                    .disabled(parsedValue == nil)
            } header: {
                Text("Correct the \(unitName)")
            } footer: {
                Text("Completed or missed follows from your goal.")
            }
        }
    }

    private func choice(_ title: String, selected: Bool, color: Color, action: @escaping () async -> Void) -> some View {
        Button {
            run("Saved", action)
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(selected ? color : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var unitName: String {
        switch goal.type {
        case .steps: "steps"
        case .workout: goal.workoutMeasure == .workoutCount ? "workouts" : "minutes"
        case .screenTime: "screen time"
        case .pickups: "pickups"
        case .wakeup: "wake-up time"
        case .overeating, .phoneBeforeBed: ""
        }
    }

    private var shortUnit: String {
        switch goal.type {
        case .workout where goal.workoutMeasure == .workoutCount: number == 1 ? "workout" : "workouts"
        case .workout, .screenTime: "min"
        default: unitName
        }
    }

    private var stepSize: Double {
        switch goal.type {
        case .steps: 500
        case .workout where goal.workoutMeasure == .workoutCount: 1
        case .workout, .screenTime: 5
        default: 1
        }
    }

    @ViewBuilder
    private var numberInput: some View {
        if goal.type == .wakeup {
            DatePicker("Woke up at", selection: wakeTime, displayedComponents: .hourAndMinute)
        } else {
            #if os(iOS)
            HStack {
                TextField(unitName.capitalized, text: $numberText)
                    .keyboardType(.numberPad)
                Text(shortUnit).foregroundStyle(.secondary)
            }
            #else
            CompactStepper(value: $number, range: 0...100_000, step: stepSize, text: Int(number).formatted(), caption: shortUnit)
                .onChange(of: number) { numberText = String(Int(number)) }
            #endif
        }
    }

    private var wakeTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .minute, value: Int(number), to: day.start())! },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                number = Double(c.hour! * 60 + c.minute!)
            }
        )
    }

    private var parsedValue: Double? {
        if goal.type == .wakeup { return number }
        return Double(numberText.filter(\.isNumber))
    }

    /// A time-of-day picker over minutes after the evening's midnight: times before noon are the next
    /// morning (12:30am = 1470).
    private func eveningTime(_ minutes: Binding<Double>) -> Binding<Date> {
        Binding(
            get: { Bedtime.date(minutes: minutes.wrappedValue, night: day) },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let clock = Double(c.hour! * 60 + c.minute!)
                minutes.wrappedValue = c.hour! < 12 ? 24 * 60 + clock : clock
            }
        )
    }

    private func loadNumber() {
        if goal.type == .phoneBeforeBed {
            let found = Bedtime.findings(metrics: owner.metrics(model), night: day)
            bedOnset = found.sleepOnset ?? 23 * 60
            bedUsedPhone = found.lastUse != nil
            bedLastUse = found.lastUse ?? bedOnset - 60
            return
        }
        number = summary?.value ?? (goal.type == .wakeup ? goal.target : 0)
        numberText = String(Int(number.rounded()))
    }

    private func save() {
        guard let value = parsedValue else { return }
        run("Saved") { await model.edit(goal, on: day, value: value) }
    }

    /// Runs a change and confirms it here; the page stays open.
    private func run(_ message: String, _ change: @escaping () async -> Void) {
        Task {
            await change()
            withAnimation { confirmation = message }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if confirmation == message { confirmation = nil } }
        }
    }
}

func daysDescription(_ days: Weekdays) -> String {
    if days == .all { return "Every day" }
    if days == .weekdays { return "Weekdays" }
    if days == Weekdays([Weekdays(weekday: 1), Weekdays(weekday: 7)]) { return "Weekends" }
    let names = Calendar.current.shortWeekdaySymbols
    return WeekdaySymbols.ordered.filter { days.contains(weekday: $0.weekday) }.map { names[$0.weekday - 1] }.joined(separator: ", ")
}
