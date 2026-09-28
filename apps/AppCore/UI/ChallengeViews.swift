import GoalKit
import SwiftUI

extension Double {
    var percent: String { formatted(.percent.precision(.fractionLength(0))) }
}

/// Compact challenge progress: name, day N of M, and overall completion.
struct ChallengeCard: View {
    var stats: ChallengeStats

    var body: some View {
        let challenge = stats.challenge
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(challenge.name, systemImage: "flag.checkered").font(.headline)
                Spacer()
                if let rate = stats.overallRate {
                    Text(rate.percent).font(.headline.monospacedDigit()).foregroundStyle(color(for: rate))
                }
            }
            Text(phaseText).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(challenge.dayNumber()), total: Double(max(challenge.totalDays(), 1)))
        }
    }

    private var phaseText: String {
        let c = stats.challenge
        switch c.phase() {
        case .upcoming: return "Starts \(c.start.start().formatted(.dateTime.month().day()))"
        case .active: return "Day \(c.dayNumber()) of \(c.totalDays()) · \(stats.perfectDays) perfect days"
        case .finished: return "Finished · \(stats.perfectDays) perfect days"
        }
    }
}

func color(for rate: Double) -> Color {
    rate >= 0.8 ? .green : (rate >= 0.5 ? .orange : .red)
}

/// Completion of each goal over the challenge.
struct ChallengeDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let stats = model.challengeStats() {
                Section {
                    ChallengeCard(stats: stats)
                    LabeledContent("Dates", value: "\(format(stats.challenge.start)) – \(format(stats.challenge.end))")
                }
                Section("Goals") {
                    ForEach(stats.goals) { goalStats in
                        GoalChallengeRow(stats: goalStats)
                    }
                }
            } else {
                Text("No challenge. Start one in Settings on your iPhone.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Challenge")
        .task { await model.loadChallengeHistory() }
    }

    private func format(_ day: DayKey) -> String {
        day.start().formatted(.dateTime.month(.abbreviated).day())
    }
}

struct GoalChallengeRow: View {
    var stats: GoalChallengeStats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(stats.goal.type.title, systemImage: stats.goal.type.symbol)
                Spacer()
                Text(stats.rate?.percent ?? "–")
                    .font(.body.monospacedDigit().bold())
                    .foregroundStyle(stats.rate.map(color(for:)) ?? .secondary)
            }
            ProgressView(value: stats.rate ?? 0)
                .tint(stats.rate.map(color(for:)) ?? .gray)
            if let average = stats.average {
                Text("Average \(GoalFormat.average(average, goal: stats.goal, estimated: stats.averageIsEstimate)) per day")
                    .font(.caption)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = ["\(stats.hits) of \(stats.counted) days"]
        if stats.unanswered > 0 { parts.append("\(stats.unanswered) unanswered") }
        if stats.bestStreak > 1 { parts.append("best streak \(stats.bestStreak)") }
        if stats.remaining > 0 { parts.append("\(stats.remaining) left") }
        return parts.joined(separator: " · ")
    }
}
