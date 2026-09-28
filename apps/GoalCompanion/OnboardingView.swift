import FamilyControls
import GoalKit
import SwiftUI

/// One-time setup. After this you shouldn't need to open the iPhone app.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    enum Step: Int, CaseIterable {
        case consent, signIn, screenTime, health, goals, shortcut, partner
    }

    @State private var step: Step = .consent

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .padding(.horizontal)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        content
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(title)
        }
    }

    private var title: String {
        switch step {
        case .consent: "Welcome"
        case .signIn: "Account"
        case .screenTime: "Screen Time"
        case .health: "Health"
        case .goals: "Your goals"
        case .shortcut: "Exact numbers"
        case .partner: "Partner"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .consent:
            Text("GolGolGol!!! checks six daily goals (steps, workouts, screen time, pickups, over-eating, and wake-up time) on your Apple Watch, and can share every data point with a partner.")
            Text("What leaves this device")
                .font(.headline)
            Text("If you sign in, your step counts, workouts, sleep-derived wake times, screen time readings, and recap answers are uploaded to the app's AWS backend so your Watch and your partner can read them. Your partner can only see your data after you give them an invite code, and can never change it. Nothing is used for advertising or sold.")
                .foregroundStyle(.secondary)
            primary("I agree") {
                await model.updatePreferences { $0.consentedToUpload = true }
                next()
            }
            secondary("Use without uploading") { next(skipping: [.signIn, .partner]) }

        case .signIn:
            if model.isSignedIn {
                Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                primary("Continue") { next() }
            } else if model.isBackendConfigured {
                Text("Sign in so your Watch can sync on its own and your partner can see your progress.")
                SignInButtons()
                secondary("Skip for now") { next() }
            } else {
                Text("This build has no backend configured (amplify_outputs.json is missing), so the app runs locally on your iPhone and Watch.")
                    .foregroundStyle(.secondary)
                primary("Continue") { next() }
            }

        case .screenTime:
            ScreenTimeSetup()
            primary("Continue") { next() }

        case .health:
            Text("GolGolGol!!! reads steps, exercise minutes, workouts, and sleep. The Watch measures these itself; the iPhone backfills when the Watch was off.")
            primary("Allow Health access") {
                do {
                    try await HealthCollector.shared.requestAuthorization()
                } catch {
                    model.errorMessage = error.localizedDescription
                }
                next()
            }
            secondary("Skip") { next() }

        case .goals:
            Text("Set your targets. You can change them any time here or on your Watch.")
            List { GoalList() }
                .listStyle(.insetGrouped)
                .frame(minHeight: 400)
            primary("Continue") { next() }

        case .shortcut:
            ShortcutWalkthrough()
            primary("Continue") { next() }
            secondary("Skip; use thresholds and self-reported pickups") { next() }

        case .partner:
            if model.isSignedIn {
                PartnerInviteSection()
            } else {
                Text("Sign in first to share with a partner. You can do it later in Settings.")
                    .foregroundStyle(.secondary)
            }
            primary("Finish") { await finish() }
        }
    }

    private func next(skipping: Set<Step> = []) {
        var candidate = Step(rawValue: step.rawValue + 1)
        while let c = candidate, skipping.contains(c) {
            candidate = Step(rawValue: c.rawValue + 1)
        }
        if let candidate {
            withAnimation { step = candidate }
        } else {
            Task { await finish() }
        }
    }

    private func finish() async {
        await model.updatePreferences { $0.onboarded = true }
        ScreenTimeMonitor.sync(with: model.data)
        await model.refresh()
    }

    private func primary(_ title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func secondary(_ title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }
}

/// Family Controls authorization and the category selection that thresholds measure.
struct ScreenTimeSetup: View {
    @ObservedObject private var authorization = AuthorizationCenter.shared
    @State private var selection = MonitoringSettings.selection
    @State private var showPicker = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screen Time is measured in the background on this iPhone. Apple keeps the numbers private, so the app gets notified as you pass each threshold (every 30 minutes up to your limit, then every 15).")
            if authorization.authorizationStatus == .approved {
                Label("Screen Time access allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Choose what counts") { showPicker = true }
                    .buttonStyle(.bordered)
                Text("\(selection.categoryTokens.count) categories, \(selection.applicationTokens.count) apps selected")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Allow Screen Time access") {
                    Task {
                        do {
                            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) {
            MonitoringSettings.selection = selection
            do {
                try Monitoring.start()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ShortcutWalkthrough: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For exact screen time and your pickup count, a Shortcut screenshots the app's Snapshot screen and reads the numbers on-device.")
            Text("1. Install both shortcuts").font(.headline)
            Text("Tap each, then choose Shortcuts in the share sheet and tap Add Shortcut.")
                .font(.callout).foregroundStyle(.secondary)
            ShortcutInstallButtons()
            Text("2. Run them from here").font(.headline)
            Text("GolGolGol!!! reminds you in the evening and the morning; tap the notification to take a snapshot. You can also use \"Take snapshot now\" on the Today screen. Change the reminder times in Settings.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Optional: in Shortcuts → Automation, add \"Charger is Connected\" → run Snapshot to take one automatically at night.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
