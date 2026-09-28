import Foundation

/// Records metrics, re-evaluates days, and keeps the local store and the backend in step.
///
/// Every device writes Metrics as it produces them, recomputes DaySummaries locally and upserts them.
/// Before evaluating a day it pulls that day's metrics from the server, so the Watch (steps, workouts,
/// sleep, recap answers) and the iPhone (screen time) converge on the same summaries.
public actor GoalEngine {
    public let store: LocalStore
    private var api: GoalAPI?
    private let calendar: Calendar

    public init(store: LocalStore, api: GoalAPI?, calendar: Calendar = .current) {
        self.store = store
        self.api = api
        self.calendar = calendar
    }

    public func setAPI(_ api: GoalAPI?) {
        self.api = api
    }

    public var isOnline: Bool { api != nil }

    // MARK: Goals

    /// Creates the default goals the first time the app runs.
    public func ensureGoals() async {
        await store.update { data in
            let existing = Set(data.goals.map(\.type))
            for goal in Goal.defaults(ownerId: data.ownerId) where !existing.contains(goal.type) {
                data.goals.append(goal)
                data.enqueue(.goal(goal))
            }
        }
    }

    public func save(_ goal: Goal) async {
        var changed = goal
        changed.id = Goal.canonicalId(goal.type)
        changed.updatedAt = .now
        let goal = changed
        await store.update { data in
            data.goals.removeAll { $0.type == goal.type }
            data.goals.append(goal)
            data.enqueue(.goal(goal))
        }
        await reevaluate(days: [DayKey.today(calendar: calendar)])
    }

    /// Merges goals from another device or the server; the most recently changed version wins.
    public func merge(goals incoming: [Goal]) async {
        let changed = await store.update { data -> Bool in
            var changed = false
            for var goal in incoming where goal.ownerId == data.ownerId {
                // Older builds (and leftover server copies) used random ids; one goal per type now.
                goal.id = Goal.canonicalId(goal.type)
                if let index = data.goals.firstIndex(where: { $0.type == goal.type }) {
                    guard goal.updatedAt > data.goals[index].updatedAt else { continue }
                    data.goals[index] = goal
                } else {
                    data.goals.append(goal)
                }
                changed = true
            }
            return changed
        }
        let today = DayKey.today(calendar: calendar)
        if changed { await reevaluate(days: [today.adding(days: -1, calendar: calendar), today]) }
    }

    // MARK: Metrics

    /// Saves new or changed metrics, queues them for upload, and re-evaluates their days.
    @discardableResult
    public func record(_ metrics: [Metric]) async -> [DaySummary] {
        let days = await store.update { data -> Set<DayKey> in
            var days = Set<DayKey>()
            for var metric in metrics {
                metric.ownerId = data.ownerId
                let key = metric.sortKey
                if let existing = data.metrics[key], existing.value == metric.value, existing.detail == metric.detail { continue }
                data.metrics[key] = metric
                data.enqueue(.metric(metric))
                days.insert(metric.date)
            }
            return days
        }
        return await reevaluate(days: Array(days))
    }

    /// Recomputes summaries for `days` and queues the ones that changed. Returns the changed summaries.
    @discardableResult
    public func reevaluate(days: [DayKey], now: Date = .now) async -> [DaySummary] {
        await store.update { data in
            var changed: [DaySummary] = []
            for day in days {
                let metrics = data.metrics.values.filter { $0.date == day }
                for summary in GoalEvaluator.evaluate(data.goals, metrics: Array(metrics), day: day, now: now, calendar: calendar) {
                    if let existing = data.summaries[summary.sortKey], existing.sameResult(as: summary) { continue }
                    data.summaries[summary.sortKey] = summary
                    data.enqueue(.summary(summary))
                    changed.append(summary)
                }
            }
            return changed
        }
    }

    // MARK: Sync

    /// Uploads queued writes. Stops at the first network failure and keeps the rest for next time.
    public func flush() async {
        guard let api else { return }
        let pending = await store.data.pending
        for (key, write) in pending.sorted(by: { $0.key < $1.key }) {
            do {
                switch write {
                case .metric(let m): try await api.put(m)
                case .summary(let s): try await api.upsert(s)
                case .goal(let g): try await api.upsert(g)
                case .profile(let p): try await api.put(p)
                }
                await store.update { data in
                    if data.pending[key] == write { data.pending[key] = nil }
                }
            } catch let error as GraphQLError where !error.isUnauthorized {
                // The server rejected this record; drop it rather than retrying forever.
                print("Dropping write \(key): \(error.message)")
                await store.update { $0.pending[key] = nil }
            } catch {
                return
            }
        }
    }

    /// Flushes, pulls goals and the given days' metrics and summaries, then re-evaluates those days.
    public func sync(days: [DayKey]) async throws {
        await flush()
        guard let api, let first = days.min(), let last = days.max() else {
            await reevaluate(days: days)
            return
        }
        let ownerId = await store.data.ownerId
        guard ownerId != LocalStore.localOwnerId else {
            await reevaluate(days: days)
            return
        }

        await merge(goals: try await api.goals(ownerId: ownerId))
        let remoteMetrics = try await api.metrics(ownerId: ownerId, from: first, through: last)
        let remoteSummaries = try await api.summaries(ownerId: ownerId, from: first, through: last)
        await store.update { data in
            for metric in remoteMetrics where data.pending["m#\(metric.sortKey)"] == nil {
                data.metrics[metric.sortKey] = metric
            }
            for summary in remoteSummaries where summary.goalId == Goal.canonicalId(summary.goalType) && data.pending["s#\(summary.sortKey)"] == nil {
                if let local = data.summaries[summary.sortKey], local.updatedAt >= summary.updatedAt { continue }
                data.summaries[summary.sortKey] = summary
            }
        }
        await reevaluate(days: days)
        await flush()
    }

    /// Pulls summaries only, for history views that span months.
    public func pullSummaries(from: DayKey, through to: DayKey) async throws {
        guard let api else { return }
        let ownerId = await store.data.ownerId
        guard ownerId != LocalStore.localOwnerId else { return }
        let remote = try await api.summaries(ownerId: ownerId, from: from, through: to)
        await store.update { data in
            for summary in remote where summary.goalId == Goal.canonicalId(summary.goalType) && data.pending["s#\(summary.sortKey)"] == nil {
                if let local = data.summaries[summary.sortKey], local.updatedAt >= summary.updatedAt { continue }
                data.summaries[summary.sortKey] = summary
            }
        }
    }

    // MARK: Partners

    public func refreshPartners(days: Int = 35) async throws {
        guard let api else { return }
        let me = await store.data.ownerId
        let shares = try await api.shares().filter { $0.viewerId == me }
        let today = DayKey.today(calendar: calendar)
        var partners: [String: PartnerData] = [:]
        for share in shares {
            var partner = PartnerData(ownerId: share.ownerId, name: share.ownerName ?? "Partner")
            // One goal per type: the canonical one, or for a partner still on an old build, their newest copy.
            let allGoals = try await api.goals(ownerId: share.ownerId)
            partner.goals = GoalType.allCases.compactMap { type in
                let copies = allGoals.filter { $0.type == type }
                return copies.first(where: \.hasCanonicalId) ?? copies.max { $0.updatedAt < $1.updatedAt }
            }
            let shownIds = Set(partner.goals.map(\.id))
            let summaries = try await api.summaries(ownerId: share.ownerId, from: today.adding(days: -days, calendar: calendar), through: today)
            partner.summaries = Dictionary(summaries.filter { shownIds.contains($0.goalId) }.map { ($0.sortKey, $0) },
                                           uniquingKeysWith: { $1 })
            let metrics = try await api.metrics(ownerId: share.ownerId, from: today, through: today)
            partner.metrics = Dictionary(metrics.map { ($0.sortKey, $0) }, uniquingKeysWith: { $1 })
            partner.fetchedAt = .now
            partners[share.ownerId] = partner
        }
        let fetched = partners
        await store.update { $0.partners = fetched }
    }

    /// Applies a live update from the partner subscription.
    public func applyPartnerUpdate(_ summary: DaySummary) async {
        await store.update { data in
            data.partners[summary.ownerId]?.summaries[summary.sortKey] = summary
        }
    }
}
