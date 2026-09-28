import GoalKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.data.preferences.onboarded {
                TabView {
                    Tab("Today", systemImage: "checkmark.circle") { NavigationStack { PhoneTodayView() } }
                    Tab("History", systemImage: "calendar") { NavigationStack { PhoneHistoryView() } }
                    Tab("Partner", systemImage: "person.2") { NavigationStack { PhonePartnerView() } }
                    Tab("Settings", systemImage: "gear") { NavigationStack { SettingsView() } }
                }
            } else {
                OnboardingView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.start() }
    }
}
