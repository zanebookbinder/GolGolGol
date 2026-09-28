import FamilyControls
import GoalKit
import SwiftUI

struct PhoneTodayView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var authorization = AuthorizationCenter.shared
    @State private var needsSelection = !Monitoring.hasSelection
    @State private var showSetup = false

    private var tracksScreenTime: Bool {
        model.data.goals.contains { $0.type == .screenTime && $0.active }
    }

    var body: some View {
        List {
            if tracksScreenTime, authorization.authorizationStatus != .approved {
                Section {
                    Button {
                        Task {
                            try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                            if AuthorizationCenter.shared.authorizationStatus == .approved { try? Monitoring.start() }
                            await model.refresh()
                        }
                    } label: {
                        Label("Screen Time access is off, so screen time can't be measured. Tap to turn it back on.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            } else if tracksScreenTime, authorization.authorizationStatus == .approved, needsSelection {
                Section {
                    Button { showSetup = true } label: {
                        Label("Screen time isn't being measured. Tap to choose what counts.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let celebration = model.tonightCelebration {
                Section { CelebrationBanner(celebration: celebration) }
            }
            ForEach(model.questionDays, id: \.self) { day in
                QuestionsCard(day: day)
            }
            if let stats = model.challengeStats() {
                Section {
                    NavigationLink { ChallengeDetailView() } label: { ChallengeCard(stats: stats) }
                }
            }
            Section {
                ForEach(model.data.activeGoals) { goal in
                    NavigationLink {
                        GoalDayView(goal: goal, day: model.today)
                    } label: {
                        GoalRowContent(goal: goal, summary: model.summary(goal, on: model.today))
                            .padding(.vertical, 4)
                    }
                }
            }
            if tracksScreenTime || model.data.goals.contains(where: { $0.type == .pickups && $0.active }) {
                SnapshotButtons()
            }
        }
        .navigationTitle("Today")
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showSetup, onDismiss: {
            needsSelection = !Monitoring.hasSelection
            Task { await model.refresh() }
        }) {
            NavigationStack {
                ScrollView { ScreenTimeSetup().padding() }
                    .navigationTitle("Screen Time")
                    .toolbar { Button("Close") { showSetup = false } }
            }
        }
    }
}

struct PhoneHistoryView: View {
    @Environment(AppModel.self) private var model
    var owner: Owner = .me

    @State private var monthOffset = 0
    @State private var selected: DayKey?

    private var month: [DayKey] {
        DayKey(Calendar.current.date(byAdding: .month, value: -monthOffset, to: .now)!).month()
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button { monthOffset += 1 } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.first!.start().formatted(.dateTime.month(.wide).year())).font(.headline)
                    Spacer()
                    Button { monthOffset -= 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(monthOffset == 0)
                }
                .buttonStyle(.borderless)
                MonthGrid(goals: goals, month: month, summary: summary, dotSize: 6) { selected = $0 }
                    .padding(.vertical, 4)
            }
            Section("This week") {
                WeekGrid(goals: goals, days: model.today.week(), summary: summary, dotSize: 14) { selected = $0 }
                    .frame(maxWidth: .infinity)
            }
            Section("Streaks") {
                ForEach(goals) { goal in
                    LabeledContent(goal.type.title, value: "\(Streaks.current(goalId: goal.id, summaries: allSummaries, today: model.today)) days")
                }
            }
        }
        .navigationTitle(owner.isMe ? "History" : owner.name(model))
        .sheet(item: $selected) { day in
            NavigationStack {
                List {
                    ForEach(goals) { goal in
                        NavigationLink {
                            GoalDayView(goal: goal, day: day, owner: owner)
                        } label: {
                            GoalRowContent(goal: goal, summary: summary(goal, day))
                        }
                    }
                }
                .navigationTitle(day.start().formatted(.dateTime.weekday().month().day()))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: monthOffset) {
            guard case .me = owner else { return }
            try? await model.engine.pullSummaries(from: month.first!, through: month.last!)
            await model.reload()
        }
    }

    private var goals: [Goal] { owner.goals(model) }

    private var allSummaries: [DaySummary] { owner.summaries(model) }

    private func summary(_ goal: Goal, _ day: DayKey) -> DaySummary? { owner.summary(model, goal, day) }
}

extension DayKey: @retroactive Identifiable {
    public var id: String { rawValue }
}
