import GoalKit
import SwiftUI

/// Partners' Today views, updated live through the AppSync subscription.
struct PhonePartnerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if !model.isSignedIn {
                Section {
                    Text("Sign in to share with a partner.")
                    SignInButtons()
                }
            } else {
                let partners = model.data.partners.values.sorted { $0.name < $1.name }
                ForEach(partners, id: \.ownerId) { partner in
                    Section(partner.name) {
                        ForEach(partner.goals.filter(\.active)) { goal in
                            NavigationLink {
                                GoalDayView(goal: goal, day: model.today, owner: .partner(partner.ownerId))
                            } label: {
                                GoalRowContent(goal: goal, summary: partner.summaries["\(model.today.rawValue)#\(goal.id)"])
                            }
                        }
                        NavigationLink("History") { PhoneHistoryView(owner: .partner(partner.ownerId)) }
                    }
                    .task(id: partner.ownerId) { await follow(partner.ownerId) }
                }
                PartnerInviteSection()
            }
        }
        .navigationTitle("Partner")
        .refreshable { await model.refreshPartners() }
        .task { await model.refreshPartners() }
    }

    /// Streams the partner's DaySummary changes; reconnects after drops.
    private func follow(_ ownerId: String) async {
        while !Task.isCancelled {
            guard let subscription = model.subscription else { return }
            do {
                for try await summary in subscription.updates(ownerId: ownerId) {
                    await model.applyPartnerUpdate(summary)
                }
            } catch {
                print("Partner subscription dropped: \(error)")
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

/// Create a code for your partner, or enter theirs.
struct PartnerInviteSection: View {
    @Environment(AppModel.self) private var model
    @State private var invite: Invite?
    @State private var code = ""
    @State private var accepted = false

    var body: some View {
        Section {
            if let invite {
                VStack(alignment: .leading, spacing: 4) {
                    Text(invite.code).font(.largeTitle.monospaced().bold()).textSelection(.enabled)
                    Text("Send this to your partner. It lets them see your data (read-only) and expires \(invite.expiresAt.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.caption).foregroundStyle(.secondary)
                    ShareLink(item: "My Golazo invite code: \(invite.code)")
                }
            } else {
                Button("Create an invite code") {
                    Task { invite = await model.createInvite() }
                }
            }
            HStack {
                TextField("Partner's code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Add") {
                    Task {
                        accepted = await model.acceptInvite(code: code)
                        if accepted { code = "" }
                    }
                }
                .disabled(code.count < 6)
            }
            if accepted {
                Label("Added. You can now see their goals.", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        } header: {
            Text("Share")
        } footer: {
            Text("Sharing is one-way per code. For two-way sharing, each of you creates a code and enters the other's.")
        }
    }
}
