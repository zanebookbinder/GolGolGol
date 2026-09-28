import Foundation

/// A write waiting to reach the backend. Keyed so newer writes of the same record replace older ones.
public enum PendingWrite: Codable, Hashable, Sendable {
    case metric(Metric)
    case summary(DaySummary)
    case goal(Goal)
    case profile(UserProfile)

    var key: String {
        switch self {
        case .metric(let m): "m#\(m.sortKey)"
        case .summary(let s): "s#\(s.sortKey)"
        case .goal(let g): "g#\(g.id)"
        case .profile(let p): "p#\(p.id)"
        }
    }
}

/// Everything a device keeps locally. Small enough to hold in memory: raw metrics are pruned after
/// `metricRetentionDays` (the backend keeps them all), summaries are kept forever.
public struct StoreData: Codable, Sendable {
    public var ownerId: String = LocalStore.localOwnerId
    public var profile: UserProfile?
    public var goals: [Goal] = []
    public var metrics: [String: Metric] = [:]
    public var summaries: [String: DaySummary] = [:]
    public var pending: [String: PendingWrite] = [:]
    public var partners: [String: PartnerData] = [:]
    public var preferences = Preferences()
    public var challenge: Challenge?

    /// The current challenge, ignoring a removed one.
    public var activeChallenge: Challenge? {
        challenge.flatMap { $0.removed ? nil : $0 }
    }

    public init() {}

    /// The day's summaries for current goals. Summaries of goals that were since replaced (e.g. by the
    /// other device's copy during sync) are ignored.
    public func summaries(for day: DayKey) -> [DaySummary] {
        let ids = Set(goals.map(\.id))
        return summaries.values.filter { $0.date == day && ids.contains($0.goalId) }
    }

    public func summary(goalId: String, day: DayKey) -> DaySummary? {
        summaries["\(day.rawValue)#\(goalId)"]
    }

    public var activeGoals: [Goal] {
        goals.filter(\.active).sorted { GoalType.allCases.firstIndex(of: $0.type)! < GoalType.allCases.firstIndex(of: $1.type)! }
    }
}

public struct PartnerData: Codable, Hashable, Sendable {
    public var ownerId: String
    public var name: String
    public var goals: [Goal] = []
    public var summaries: [String: DaySummary] = [:]
    public var metrics: [String: Metric] = [:]
    public var fetchedAt: Date?

    public init(ownerId: String, name: String) {
        self.ownerId = ownerId
        self.name = name
    }
}

public struct Preferences: Codable, Hashable, Sendable {
    /// Minutes after midnight. Default 9:30pm.
    public var recapMinutes: Int = 21 * 60 + 30
    public var recapAnswered: Set<DayKey> = []
    public var consentedToUpload = false
    public var onboarded = false

    public init() {}
}

/// JSON-file store shared by the app and (via the App Group) its widgets.
public actor LocalStore {
    public static let localOwnerId = "local"
    public static let metricRetentionDays = 62

    public nonisolated let url: URL
    private(set) public var data: StoreData

    public init(url: URL) {
        self.url = url
        var data = Self.read(from: url) ?? StoreData()
        if data.canonicalizeGoals() { Self.write(data, to: url) }
        self.data = data
    }

    /// For widgets and other read-only callers that don't need the actor.
    public static func read(from url: URL) -> StoreData? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return try? GoalJSON.decoder.decode(StoreData.self, from: bytes)
    }

    public func update<T: Sendable>(_ body: @Sendable (inout StoreData) throws -> T) rethrows -> T {
        let result = try body(&data)
        save()
        return result
    }

    private func save() {
        Self.write(data, to: url)
    }

    private static func write(_ data: StoreData, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoded = try GoalJSON.encoder.encode(data)
            try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #if DEBUG
            // A copy in the app's own container, which `devicectl` can read for debugging (the App Group can't be).
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                try? encoded.write(to: caches.appending(path: "store-debug.json"), options: .atomic)
            }
            #endif
        } catch {
            print("LocalStore save failed: \(error)")
        }
    }

    /// Moves everything recorded before sign-in to the signed-in user.
    public func adoptOwner(_ ownerId: String) {
        guard data.ownerId != ownerId else { return }
        update { data in
            data.ownerId = ownerId
            data.goals = data.goals.map { var g = $0; g.ownerId = ownerId; return g }
            data.metrics = data.metrics.mapValues { var m = $0; m.ownerId = ownerId; return m }
            data.summaries = data.summaries.mapValues { var s = $0; s.ownerId = ownerId; return s }
            data.pending = [:]
            for goal in data.goals { data.enqueue(.goal(goal)) }
            for metric in data.metrics.values { data.enqueue(.metric(metric)) }
            for summary in data.summaries.values { data.enqueue(.summary(summary)) }
        }
    }

    public func pruneOldMetrics(today: DayKey = .today()) {
        let cutoff = today.adding(days: -Self.metricRetentionDays)
        update { $0.metrics = $0.metrics.filter { $0.value.date >= cutoff } }
    }
}

extension StoreData {
    public mutating func enqueue(_ write: PendingWrite) {
        pending[write.key] = write
    }

    /// Early builds gave each device's goals random ids, so the same goal existed several times (and
    /// its results were split between them). Collapses to one goal per type with the canonical id,
    /// and one summary per day and type, keeping the best: the current goal's, then a settled one,
    /// then the newest. Everything kept is re-uploaded under the canonical ids. Returns true if anything changed.
    mutating func canonicalizeGoals() -> Bool {
        let needed = goals.contains { !$0.hasCanonicalId }
            || Set(goals.map(\.type)).count != goals.count
            || summaries.values.contains { $0.goalId != Goal.canonicalId($0.goalType) }
        guard needed else { return false }

        let currentIds = Set(goals.map(\.id))
        var newest: [GoalType: Goal] = [:]
        for goal in goals where (newest[goal.type]?.updatedAt ?? .distantPast) < goal.updatedAt {
            newest[goal.type] = goal
        }
        goals = GoalType.allCases.compactMap { newest[$0] }.map { goal in
            var canonical = goal
            canonical.id = Goal.canonicalId(goal.type)
            canonical.updatedAt = .now // newer than any leftover copy on the server
            return canonical
        }

        func rank(_ s: DaySummary) -> (Int, Int, Date) {
            (currentIds.contains(s.goalId) ? 1 : 0, s.status == .pending ? 0 : 1, s.updatedAt)
        }
        var best: [String: (rank: (Int, Int, Date), summary: DaySummary)] = [:]
        for summary in summaries.values {
            var canonical = summary
            canonical.goalId = Goal.canonicalId(summary.goalType)
            let r = rank(summary)
            if let existing = best[canonical.sortKey], existing.rank >= r { continue }
            best[canonical.sortKey] = (r, canonical)
        }
        summaries = best.mapValues(\.summary)

        pending = pending.filter { key, _ in !key.hasPrefix("s#") && !key.hasPrefix("g#") }
        for goal in goals { enqueue(.goal(goal)) }
        for summary in summaries.values { enqueue(.summary(summary)) }
        return true
    }

    /// Moves a replaced goal's history to its replacement, so streaks and past days carry over.
    mutating func moveSummaries(from oldGoalId: String, to newGoalId: String) {
        for (key, summary) in summaries where summary.goalId == oldGoalId {
            summaries[key] = nil
            pending["s#\(key)"] = nil
            var moved = summary
            moved.goalId = newGoalId
            if summaries[moved.sortKey] == nil {
                summaries[moved.sortKey] = moved
                enqueue(.summary(moved))
            }
        }
    }
}
