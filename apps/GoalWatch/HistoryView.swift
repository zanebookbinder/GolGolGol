import GoalKit
import SwiftUI

/// Day, week, and month views. The ‹ › arrows step through periods (horizontal swipes move between
/// the app's pages). Tap a day in the week or month to see that day; tap a goal for its page.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    var owner: Owner = .me

    enum Scale: String, CaseIterable {
        case day = "Day", week = "Week", month = "Month"
    }

    @State private var scale: Scale = .week
    /// 0 = current period, 1 = one back, …
    @State private var offset = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Scale.allCases, id: \.self) { option in
                        Button {
                            scale = option
                            offset = 0
                        } label: {
                            Text(option.rawValue)
                                .font(.caption.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(option == scale ? Color.accentColor : Color.gray.opacity(0.3), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == scale ? .isSelected : [])
                    }
                }

                HStack(spacing: 4) {
                    Button { offset = min(offset + 1, 365) } label: { Image(systemName: "chevron.left.circle.fill") }
                        .accessibilityLabel("Earlier")
                    Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                    Button { offset = max(offset - 1, 0) } label: { Image(systemName: "chevron.right.circle.fill") }
                        .accessibilityLabel("Later")
                        .disabled(offset == 0)
                }
                .buttonStyle(.plain)
                .font(.title3)

                switch scale {
                case .day: dayList
                case .week: WeekGrid(goals: goals, days: anchor.week(), summary: summary, onSelect: show)
                case .month: MonthGrid(goals: goals, month: anchor.month(), summary: summary, dotSize: 3.5, onSelect: show)
                }
            }
        }
        .task(id: "\(scale.rawValue)\(offset)") {
            guard case .me = owner else { return }
            let days = scale == .month ? anchor.month() : anchor.week()
            try? await model.engine.pullSummaries(from: days.first!, through: days.last!)
            await model.reload()
        }
        .modifier(PartnerTitle(owner: owner))
    }

    /// Your History is a page whose title comes from the page view; a partner's is pushed and titles itself.
    private struct PartnerTitle: ViewModifier {
        var owner: Owner

        func body(content: Content) -> some View {
            if case .partner = owner {
                content.navigationTitle("History")
            } else {
                content
            }
        }
    }

    /// Switches to the day view on `day`.
    private func show(_ day: DayKey) {
        scale = .day
        offset = DayKey.range(day, through: model.today).count - 1
    }

    private var anchor: DayKey {
        let today = model.today
        switch scale {
        case .day: return today.adding(days: -offset)
        case .week: return today.adding(days: -7 * offset)
        case .month:
            let date = Calendar.current.date(byAdding: .month, value: -offset, to: today.start())!
            return DayKey(date)
        }
    }

    private var title: String {
        let start = anchor.start()
        switch scale {
        case .day: return offset == 0 ? "Today" : start.formatted(.dateTime.weekday().month().day())
        case .week: return offset == 0 ? "This week" : "Week of \(anchor.week().first!.start().formatted(.dateTime.month().day()))"
        case .month: return start.formatted(.dateTime.month(.wide).year())
        }
    }

    private var goals: [Goal] { owner.goals(model) }

    private func summary(_ goal: Goal, _ day: DayKey) -> DaySummary? { owner.summary(model, goal, day) }

    private var dayList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(goals) { goal in
                NavigationLink {
                    GoalDayView(goal: goal, day: anchor, owner: owner)
                } label: {
                    GoalRowContent(goal: goal, summary: summary(goal, anchor))
                }
            }
        }
    }
}
