import DeviceActivity
import GoalKit
import SwiftUI

struct SnapshotConfiguration {
    var minutes: Int
    var pickups: Int
    var day: Date?
}

struct SnapshotReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .snapshot
    let content: (SnapshotConfiguration) -> SnapshotReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> SnapshotConfiguration {
        var total: TimeInterval = 0
        var pickups = 0
        var day: Date?
        for await deviceData in data {
            for await segment in deviceData.activitySegments {
                total += segment.totalActivityDuration
                day = day ?? segment.dateInterval.start
                // Spike question: per-app pickups count pickups that opened an app, so this sum may
                // run lower than the Settings > Screen Time total. Compare the two during Phase 0.
                for await category in segment.categories {
                    for await app in category.applications {
                        pickups += app.numberOfPickups
                    }
                }
            }
        }
        return SnapshotConfiguration(minutes: Int(total / 60), pickups: pickups, day: day)
    }
}

/// Two large numbers, high contrast, fixed font, nothing else, so on-device OCR reads them reliably.
/// The labels must stay in sync with `SnapshotParser`.
struct SnapshotReportView: View {
    let configuration: SnapshotConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let day = configuration.day {
                Text("\(SnapshotParser.dateLabel) \(day.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))")
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .padding(.bottom, 24)
            }
            label(SnapshotParser.screenTimeLabel)
            value("\(configuration.minutes) min")
                .padding(.bottom, 24)
            label(SnapshotParser.pickupsLabel)
            value("\(configuration.pickups)")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(32)
        .background(.black)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 32, weight: .bold, design: .monospaced))
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.system(size: 72, weight: .bold, design: .monospaced))
    }
}
