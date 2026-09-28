import GoalKit
import SwiftUI

/// Today's goals, with the recap questions at the top when they're due (tonight, or yesterday's if
/// still unanswered). Tap a goal for its page.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.questionDays, id: \.self) { day in
                QuestionsCard(day: day)
            }

            if let stats = model.challengeStats() {
                NavigationLink {
                    ChallengeDetailView()
                } label: {
                    ChallengeCard(stats: stats)
                }
            }

            Section {
                ForEach(model.data.activeGoals) { goal in
                    NavigationLink {
                        GoalDayView(goal: goal, day: model.today)
                    } label: {
                        GoalRowContent(goal: goal, summary: model.summary(goal, on: model.today))
                    }
                }
            } header: {
                Text("\(hitCount) of \(applicableCount) completed")
            } footer: {
                Text("Swipe for History, Partner, and Settings.")
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }

    private var todays: [DaySummary] { model.data.summaries(for: model.today) }
    private var hitCount: Int { todays.filter { $0.status == .hit }.count }
    private var applicableCount: Int { todays.filter { $0.status != .off }.count }
}
