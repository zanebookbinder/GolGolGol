import GoalKit
import SwiftUI

/// Create or change the challenge period. Syncs to the Watch.
struct ChallengeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Challenge"
    @State private var start = Calendar.current.startOfDay(for: .now)
    @State private var end = Calendar.current.date(byAdding: .day, value: 29, to: Calendar.current.startOfDay(for: .now))!
    @State private var confirmRemove = false

    private var existing: Challenge? { model.data.activeChallenge }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                DatePicker("Start", selection: $start, displayedComponents: .date)
                DatePicker("End", selection: $end, in: start..., displayedComponents: .date)
                LabeledContent("Length", value: "\(DayKey.range(DayKey(start), through: DayKey(end)).count) days")
            } footer: {
                Text("Tracks how often you hit each goal between these dates. Days before you installed the app count as unanswered.")
            }
            Section {
                ForEach([30, 60, 90], id: \.self) { days in
                    Button("\(days) days from start") {
                        end = Calendar.current.date(byAdding: .day, value: days - 1, to: start)!
                    }
                }
            }
            if existing != nil {
                Section {
                    Button("Remove challenge", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .navigationTitle(existing == nil ? "New challenge" : "Challenge")
        .toolbar {
            Button("Save") {
                Task {
                    await model.setChallenge(Challenge(name: name.isEmpty ? "Challenge" : name, start: DayKey(start), end: DayKey(end)))
                    dismiss()
                }
            }
        }
        .confirmationDialog("Remove this challenge?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.removeChallenge()
                    dismiss()
                }
            }
        } message: {
            Text("Your goal history is kept; only the challenge period is removed.")
        }
        .onAppear {
            guard let existing else { return }
            name = existing.name
            start = existing.start.start()
            end = existing.end.start()
        }
    }
}
