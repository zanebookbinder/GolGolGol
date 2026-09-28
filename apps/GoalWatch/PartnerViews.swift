import GoalKit
import SwiftUI

/// Partners who share with you. watchOS doesn't allow WebSocket subscriptions outside audio apps,
/// so this polls every minute while it's the page on screen.
struct PartnerListView: View {
    @Environment(AppModel.self) private var model
    /// Pages stay loaded when swiped away, so polling is tied to being the current page.
    var isVisible: Bool

    var body: some View {
        List {
            let partners = model.data.partners.values.sorted { $0.name < $1.name }
            if !model.isSignedIn {
                Text("Sign in on your iPhone to see your partner.")
                    .foregroundStyle(.secondary)
            } else if partners.isEmpty {
                Text("No one is sharing with you yet. Enter an invite code on your iPhone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(partners, id: \.ownerId) { partner in
                NavigationLink {
                    PartnerTodayView(partnerId: partner.ownerId)
                } label: {
                    VStack(alignment: .leading) {
                        Text(partner.name).font(.headline)
                        Text(summaryLine(partner)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: isVisible) {
            while isVisible, model.isSignedIn, !Task.isCancelled {
                await model.refreshPartners()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func summaryLine(_ partner: PartnerData) -> String {
        let today = partner.summaries.values.filter { $0.date == model.today && $0.status != .off }
        return "\(today.filter { $0.status == .hit }.count) of \(today.count) completed today"
    }
}

struct PartnerTodayView: View {
    @Environment(AppModel.self) private var model
    var partnerId: String

    private var partner: PartnerData? { model.data.partners[partnerId] }

    var body: some View {
        List {
            if let partner {
                ForEach(partner.goals.filter(\.active)) { goal in
                    NavigationLink {
                        GoalDayView(goal: goal, day: model.today, owner: .partner(partnerId))
                    } label: {
                        GoalRowContent(goal: goal, summary: partner.summaries["\(model.today.rawValue)#\(goal.id)"])
                    }
                }
                NavigationLink {
                    HistoryView(owner: .partner(partnerId))
                } label: {
                    Label("History", systemImage: "calendar")
                }
                if let fetched = partner.fetchedAt {
                    Text("Updated \(fetched.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(partner?.name ?? "Partner")
    }
}
