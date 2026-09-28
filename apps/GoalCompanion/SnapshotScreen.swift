import DeviceActivity
import SwiftUI

/// Which day the Snapshot screen reports: `goaltracker://snapshot` or `goaltracker://snapshot?day=yesterday`.
enum SnapshotDay: String, Identifiable {
    case today, yesterday

    var id: String { rawValue }

    var url: URL {
        URL(string: self == .today ? "goaltracker://snapshot" : "goaltracker://snapshot?day=yesterday")!
    }

    var filter: DeviceActivityFilter {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = self == .today ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return DeviceActivityFilter(
            segment: .daily(during: DateInterval(start: start, end: end)),
            users: .all,
            devices: .init([.iPhone])
        )
    }
}

/// Full-screen host for the report extension; the Snapshot shortcut screenshots this.
struct SnapshotScreen: View {
    let day: SnapshotDay
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DeviceActivityReport(.snapshot, filter: day.filter)
            .background(.black)
            .ignoresSafeArea()
            .statusBarHidden()
            .overlay(alignment: .topTrailing) {
                // An icon rather than a text button, so OCR doesn't pick up extra words.
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.gray)
                }
                .accessibilityLabel("Close")
                .padding()
            }
    }
}
