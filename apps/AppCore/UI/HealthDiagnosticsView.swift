import SwiftUI

/// Health permission status and what the last HealthKit reads returned.
struct HealthDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var status = "…"
    @State private var lines: [String] = []

    var body: some View {
        List {
            Section("Permission prompt") {
                Text(status)
                Button("Ask for Health access again") {
                    Task {
                        try? await HealthCollector.shared.requestAuthorization()
                        await reload()
                    }
                }
            }
            Section("Last reads") {
                if lines.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(lines.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
            }
            Section {
                Button("Read Health now") {
                    Task {
                        await model.refresh()
                        await reload()
                    }
                }
            }
        }
        .navigationTitle("Health")
        .task { await reload() }
    }

    private func reload() async {
        status = await HealthCollector.shared.authorizationRequestStatus()
        lines = HealthCollector.shared.diagnostics
    }
}
