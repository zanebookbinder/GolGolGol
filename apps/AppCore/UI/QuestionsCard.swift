import GoalKit
import SwiftUI

extension AppModel {
    /// Days with recap questions to show on Today: yesterday if anything's unanswered, and today once
    /// it's recap time (before that, over-eating is always unanswered, so asking would be noise).
    var questionDays: [DayKey] {
        var days: [DayKey] = []
        if !questions(for: yesterday).isEmpty { days.append(yesterday) }
        let minutesNow = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let now = (minutesNow.hour ?? 0) * 60 + (minutesNow.minute ?? 0)
        if now >= data.preferences.recapMinutes, !questions(for: today).isEmpty { days.append(today) }
        return days
    }

    func questions(for day: DayKey) -> [GoalType] {
        GoalEvaluator.questions(for: data.summaries(for: day))
            .sorted { GoalType.allCases.firstIndex(of: $0)! < GoalType.allCases.firstIndex(of: $1)! }
    }
}

/// The nightly questions for one day, as sections at the top of Today. Answering one records it
/// (as a manual result, the same as correcting the goal's page) and the question goes away.
struct QuestionsCard: View {
    @Environment(AppModel.self) private var model
    var day: DayKey

    var body: some View {
        ForEach(model.questions(for: day), id: \.self) { type in
            Section {
                HStack(spacing: 6) {
                    button(type, yes: true)
                    button(type, yes: false)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("\(day == model.today ? "Tonight" : "Yesterday"): \(question(for: type))")
                    .lineLimit(2)
            }
        }
    }

    private func question(for type: GoalType) -> String {
        let goal = model.data.goals.first { $0.type == type }
        switch type {
        case .overeating: return "Did you over-eat?"
        case .pickups: return "Under \(Int(goal?.target ?? 0)) pickups?"
        case .wakeup: return "Up by \(GoalFormat.clock(minutesAfterMidnight: (goal?.target ?? 0) + GoalEvaluator.wakeupToleranceMinutes))?"
        default: return type.title
        }
    }

    private func button(_ type: GoalType, yes: Bool) -> some View {
        Button {
            Task { await model.answer(type, yes: yes, day: day) }
        } label: {
            Text(yes ? "Yes" : "No")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("\(type.rawValue)-\(yes ? "yes" : "no")")
    }
}
