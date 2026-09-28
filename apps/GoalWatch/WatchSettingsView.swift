import GoalKit
import SwiftUI

/// Kept minimal; the iPhone app mirrors it with more room.
struct WatchSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var invite: Invite?

    var body: some View {
        List {
            Section("Goals") {
                ForEach(model.data.goals.sorted { GoalType.allCases.firstIndex(of: $0.type)! < GoalType.allCases.firstIndex(of: $1.type)! }) { goal in
                    NavigationLink {
                        GoalEditor(goal: goal) { edited in
                            Task { await model.save(edited) }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(goal.type.title)
                            Text(goal.active ? GoalFormat.target(goal) : "Off")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Recap") {
                DatePicker("Time", selection: recapTime, displayedComponents: .hourAndMinute)
            }

            Section {
                NavigationLink("Health diagnostics") { HealthDiagnosticsView() }
            }

            Section("Sharing") {
                if model.isSignedIn {
                    if let invite {
                        VStack(alignment: .leading) {
                            Text(invite.code).font(.title2.monospaced().bold())
                            Text("Expires \(invite.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Create invite code") {
                            Task { invite = await model.createInvite() }
                        }
                    }
                } else {
                    Text(model.isBackendConfigured ? "Sign in on your iPhone to share." : "Sharing needs the backend.")
                        .foregroundStyle(.secondary)
                }
            }
        }
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
