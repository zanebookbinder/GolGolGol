import GoalKit
import SwiftUI

/// Edits one goal's target (and for wakeup, the time and which days it applies). Used by both apps.
/// Changes save as you make them, so leaving the app mid-edit doesn't lose them.
struct GoalEditor: View {
    @State var goal: Goal
    var onSave: (Goal) -> Void
    @State private var pendingSave: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("Track this goal", isOn: $goal.active)
            }
            if goal.active {
                targetSection
                if goal.type == .wakeup {
                    Section {
                        WeekdayPicker(days: $goal.days)
                    } header: {
                        Text("Days")
                    } footer: {
                        Text("Other days show as off and don't break a streak.")
                    }
                }
            }
        }
        .navigationTitle(goal.type.title)
        .onChange(of: goal) {
            // Steppers change in quick bursts; save once they settle.
            pendingSave?.cancel()
            pendingSave = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                onSave(goal)
                pendingSave = nil
            }
        }
        .onDisappear {
            if pendingSave != nil {
                pendingSave?.cancel()
                onSave(goal)
            }
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        switch goal.type {
        case .steps:
            Section("Daily target") {
                CompactStepper(value: $goal.target, range: 1_000...50_000, step: 500, text: Int(goal.target).formatted(), caption: "steps")
            }
        case .workout:
            Section {
                Picker("Measure", selection: Binding(
                    get: { goal.workoutMeasure ?? .longestWorkout },
                    set: { measure in
                        guard measure != goal.workoutMeasure else { return }
                        goal.workoutMeasure = measure
                        goal.target = measure.defaultTarget
                    }
                )) {
                    ForEach(WorkoutMeasure.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if goal.workoutMeasure == .workoutCount {
                    CompactStepper(value: $goal.target, range: 1...5, text: "\(Int(goal.target))", caption: goal.target == 1 ? "workout" : "workouts")
                } else {
                    CompactStepper(value: $goal.target, range: 5...180, step: 5, text: "\(Int(goal.target))", caption: "minutes")
                }
            } header: {
                Text("Daily target")
            } footer: {
                switch goal.workoutMeasure ?? .longestWorkout {
                case .workoutCount: Text("Any logged workout counts (run, strength, cycling, swimming, and so on) except walks.")
                case .longestWorkout: Text("Needs a single logged workout at least this long.")
                case .exerciseMinutes: Text("Uses the Exercise ring's minutes, from any activity.")
                }
            }
        case .screenTime:
            Section {
                CompactStepper(value: $goal.target, range: 15...600, step: 15, text: GoalFormat.duration(minutes: goal.target), caption: "at most")
            } header: {
                Text("Daily limit")
            } footer: {
                Text("Reaching the limit counts as missed.")
            }
        case .pickups:
            Section("Daily limit") {
                CompactStepper(value: $goal.target, range: 5...500, step: 5, text: "\(Int(goal.target))", caption: "pickups at most")
            }
        case .overeating:
            Section {
                Text("Answered each night in the recap.")
                    .foregroundStyle(.secondary)
            }
        case .phoneBeforeBed:
            Section {
                CompactStepper(value: $goal.target, range: 10...120, step: 5, text: "\(Int(goal.target))", caption: "minutes before sleep")
            } header: {
                Text("No phone for")
            } footer: {
                Text("Uses the time you fell asleep from Sleep, and phone use picked up by Screen Time between 9 PM and 3 AM.")
            }
        case .wakeup:
            Section {
                DatePicker("Wake by", selection: wakeTime, displayedComponents: .hourAndMinute)
            } header: {
                Text("Wake-up time")
            } footer: {
                Text("Uses the last time you woke up in your sleep data. Up to \(Int(GoalEvaluator.wakeupToleranceMinutes)) minutes late still counts.")
            }
        }
    }

    private var wakeTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .minute, value: Int(goal.target), to: Calendar.current.startOfDay(for: .now))! },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                goal.target = Double(c.hour! * 60 + c.minute!)
            }
        )
    }
}

/// Seven toggle buttons, one per weekday.
struct WeekdayPicker: View {
    @Binding var days: Weekdays

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WeekdaySymbols.ordered, id: \.weekday) { item in
                let on = days.contains(weekday: item.weekday)
                Button {
                    if on { days.remove(Weekdays(weekday: item.weekday)) } else { days.insert(Weekdays(weekday: item.weekday)) }
                } label: {
                    Text(item.symbol)
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(on ? Color.accentColor : Color.gray.opacity(0.2), in: Capsule())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[item.weekday - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
