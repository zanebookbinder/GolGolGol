import FamilyControls
import GoalKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var displayName = ""

    var body: some View {
        List {
            Section("Goals") {
                GoalList()
            }

            Section("Challenge") {
                NavigationLink {
                    ChallengeEditor()
                } label: {
                    if let challenge = model.data.activeChallenge {
                        LabeledContent(challenge.name, value: "\(challenge.start.start().formatted(.dateTime.month(.abbreviated).day())) – \(challenge.end.start().formatted(.dateTime.month(.abbreviated).day()))")
                    } else {
                        Label("Start a challenge", systemImage: "flag.checkered")
                    }
                }
            }

            Section("Recap") {
                DatePicker("Nightly recap", selection: recapTime, displayedComponents: .hourAndMinute)
            }

            Section("Health") {
                NavigationLink("Health access and diagnostics") { HealthDiagnosticsView() }
            }

            Section("Screen Time") {
                ScreenTimeSetup()
                LabeledContent("Monitoring", value: Monitoring.isActive ? "Active" : "Not running")
                NavigationLink("Snapshot log") { SnapshotLogView() }
            }

            Section {
                ShortcutInstallButtons()
                SnapshotReminderSettings()
            } header: {
                Text("Snapshot shortcut")
            } footer: {
                Text("Tapping a reminder runs the snapshot. In the share sheet, choose Shortcuts to install.")
            }

            Section("Sharing") {
                if model.isSignedIn {
                    NavigationLink("Manage sharing") { SharingView() }
                } else {
                    Text("Sign in to share with a partner.").foregroundStyle(.secondary)
                }
            }

            Section("Account") {
                if model.isSignedIn {
                    TextField("Display name", text: $displayName)
                        .onSubmit { Task { await model.setDisplayName(displayName) } }
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                } else if model.isBackendConfigured {
                    SignInButtons()
                } else {
                    Text("Local only: this build has no backend.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear { displayName = model.data.profile?.displayName ?? "" }
    }

    private var recapTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .minute, value: model.data.preferences.recapMinutes, to: Calendar.current.startOfDay(for: .now))! },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                Task { await model.setRecapMinutes(c.hour! * 60 + c.minute!) }
            }
        )
    }
}

/// Goals with links to their editors. Used in onboarding and Settings.
struct GoalList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.data.goals.sorted { GoalType.allCases.firstIndex(of: $0.type)! < GoalType.allCases.firstIndex(of: $1.type)! }) { goal in
            NavigationLink {
                GoalEditor(goal: goal) { edited in
                    Task { await model.save(edited) }
                }
            } label: {
                LabeledContent {
                    Text(goal.active ? detail(goal) : "Off")
                } label: {
                    Label(goal.type.title, systemImage: goal.type.symbol)
                }
            }
        }
    }

    private func detail(_ goal: Goal) -> String {
        goal.type == .wakeup ? "\(GoalFormat.target(goal)), \(daysDescription(goal.days))" : GoalFormat.target(goal)
    }
}

struct SharingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            PartnerInviteSection()
            let me = model.data.ownerId
            let viewers = model.shares.filter { $0.ownerId == me }
            let viewing = model.shares.filter { $0.viewerId == me }
            Section("Can see your data") {
                if viewers.isEmpty { Text("No one").foregroundStyle(.secondary) }
                ForEach(viewers) { share in
                    Text(share.viewerName ?? "Partner")
                        .swipeActions { Button("Remove", role: .destructive) { Task { await model.remove(share) } } }
                }
            }
            Section("You can see") {
                if viewing.isEmpty { Text("No one").foregroundStyle(.secondary) }
                ForEach(viewing) { share in
                    Text(share.ownerName ?? "Partner")
                        .swipeActions { Button("Stop", role: .destructive) { Task { await model.remove(share) } } }
                }
            }
        }
        .navigationTitle("Sharing")
        .task { await model.refreshPartners() }
    }
}

/// Recent threshold crossings and snapshots, to spot OCR failures.
struct SnapshotLogView: View {
    @State private var events = EventLog.read().reversed() as [LoggedEvent]

    var body: some View {
        List(events) { event in
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .foregroundStyle(event.kind == .snapshotRejected || event.kind == .error ? .red : .primary)
                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay { if events.isEmpty { ContentUnavailableView("No events yet", systemImage: "list.bullet") } }
        .navigationTitle("Snapshot log")
        .toolbar {
            Button("Clear") {
                EventLog.clear()
                events = []
            }
        }
    }
}
