import Foundation
import GoalKit
import Observation

/// App state shared by the iPhone and Watch apps: the local store, sync, sign-in, and partners.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store: LocalStore
    let engine: GoalEngine
    let config: BackendConfig?
    let auth: CognitoAuth?

    private(set) var data = StoreData()
    private(set) var session: AuthSession?
    private(set) var shares: [Share] = []
    private(set) var isRefreshing = false
    var errorMessage: String?

    /// Run after local data changes (reload widgets, update the other device).
    @ObservationIgnored var onChange: [(StoreData) -> Void] = []
    /// Run with new screen time and pickup readings (the iPhone forwards them to the Watch).
    @ObservationIgnored var onScreenTimeReadings: (([Metric]) -> Void)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshRequested = false

    private init() {
        store = LocalStore(url: AppGroup.storeURL)
        config = BackendConfig.load()
        auth = config.map { CognitoAuth(config: $0, store: AppGroup.keychain) }
        engine = GoalEngine(store: store, api: nil)
        session = AppGroup.keychain.load()
    }

    var isSignedIn: Bool { session != nil }
    var isBackendConfigured: Bool { config != nil }
    var today: DayKey { .today() }
    var yesterday: DayKey { today.adding(days: -1) }

    private var api: GoalAPI? {
        guard let config, let auth, session != nil else { return nil }
        return GoalAPI(client: GraphQLClient(url: config.graphQLURL, auth: auth))
    }

    var subscription: SummarySubscription? {
        guard let config, let auth, session != nil else { return nil }
        return SummarySubscription(client: GraphQLClient(url: config.graphQLURL, auth: auth))
    }

    func start() async {
        guard !started else { return }
        started = true
        if let userId = session?.userId { await store.adoptOwner(userId) }
        await engine.setAPI(api)
        await engine.ensureGoals()
        await store.pruneOldMetrics()
        await reload()
    }

    func reload() async {
        data = await store.data
        for handler in onChange { handler(data) }
    }

    // MARK: Data

    /// Pulls in HealthKit and inbox readings, syncs yesterday and today with the server, and re-evaluates.
    /// Requests made while a refresh is running (e.g. right after Health access is granted) run once
    /// it finishes, rather than being dropped.
    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        repeat {
            refreshRequested = false
            await start()
            let inbox = AppGroup.inbox.drain()
            if !inbox.isEmpty {
                await engine.record(inbox)
                onScreenTimeReadings?(inbox)
            }
            await collectHealth(days: [yesterday, today])
            do {
                try await engine.sync(days: [yesterday, today])
            } catch {
                report(error)
            }
            await reload()
        } while refreshRequested
    }

    func collectHealth(days: [DayKey]) async {
        var metrics: [Metric] = []
        for day in days {
            metrics += await HealthCollector.shared.collect(day: day, ownerId: data.ownerId)
        }
        if !metrics.isEmpty { await engine.record(metrics) }
    }

    /// Saves locally and updates the screen right away; the upload happens after.
    func record(_ metrics: [Metric]) async {
        await engine.record(metrics)
        await reload()
        let screenTime = metrics.filter { $0.type == .screenTime || $0.type == .pickups }
        if !screenTime.isEmpty { onScreenTimeReadings?(screenTime) }
        await engine.flush()
        await reload()
    }

    /// A recap answer, recorded as a manual result (the same as setting it on the goal's page, so one
    /// Reset undoes either). Over-eating: `yes` = over-ate. Pickups and wake-up: `yes` = goal met.
    func answer(_ type: GoalType, yes: Bool, day: DayKey) async {
        guard let goal = data.activeGoals.first(where: { $0.type == type }) else { return }
        await edit(goal, on: day, hit: type == .overeating ? !yes : yes)
    }

    func save(_ goal: Goal) async {
        await engine.save(goal)
        await reload()
        await engine.flush()
        await reload()
    }

    func setRecapMinutes(_ minutes: Int) async {
        await store.update { $0.preferences.recapMinutes = minutes }
        await reload()
    }

    func updatePreferences(_ change: @escaping @Sendable (inout Preferences) -> Void) async {
        await store.update { change(&$0.preferences) }
        await reload()
    }

    func summary(_ goal: Goal, on day: DayKey) -> DaySummary? {
        data.summary(goalId: goal.id, day: day)
    }

    // MARK: Manual edits

    /// Sets a day's number for a goal (steps, workouts or workout minutes, screen time minutes,
    /// pickups, or wake time as minutes after midnight). Hit or missed follows from the target.
    func edit(_ goal: Goal, on day: DayKey, value: Double) async {
        await writeEdit(goal, day, kind: MetricKind.overrideValue, value: value)
    }

    /// Marks a goal done or missed for a day, regardless of measured data.
    func edit(_ goal: Goal, on day: DayKey, hit: Bool) async {
        await writeEdit(goal, day, kind: MetricKind.overrideStatus, value: hit ? 1 : 0)
    }

    /// Goes back to measured data for that day: removes a manual edit and any recap answer, so a
    /// self-reported goal (over-eating, pickups or wake-up without data) is unanswered again.
    func clearEdit(_ goal: Goal, on day: DayKey) async {
        await clearOverrides(goal, on: day)
        if goal.type == .phoneBeforeBed {
            // Also drop corrected bedtime / last-use times, back to what sleep data and Screen Time found.
            let cleared = [Bedtime.onsetEditId(day), Bedtime.lastUseEditId(day)]
                .filter { id in data.metrics.values.contains { $0.id == id && $0.date == day } }
                .map { Metric(id: $0, ownerId: data.ownerId, date: day, type: .phoneBeforeBed, source: .manual, value: 0,
                              detail: [MetricKind.key: MetricKind.overrideCleared]) }
            if !cleared.isEmpty { await record(cleared) }
        }
        // Raw readings for old days may no longer be on this device; fetch them to re-evaluate.
        try? await engine.sync(days: [day])
        await reload()
    }

    /// Removes a Completed/Missed edit and any recap answer.
    private func clearOverrides(_ goal: Goal, on day: DayKey) async {
        if data.metrics.values.contains(where: { $0.id == MetricKind.answerId(goal.type, day) && $0.date == day }) {
            await record([Metric(id: MetricKind.answerId(goal.type, day), ownerId: data.ownerId, date: day, type: goal.type,
                                 source: .manual, value: 0, detail: [MetricKind.key: MetricKind.answerCleared])])
        }
        await writeEdit(goal, day, kind: MetricKind.overrideCleared, value: 0)
    }

    /// Corrects what the phone-before-bed goal found for `night`: when you fell asleep, and your last
    /// phone use before it (`nil` = none that evening). Times are minutes after the evening's midnight
    /// (12:30am = 1470). Completed or missed then follows from the corrected times.
    func setBedtime(_ goal: Goal, night: DayKey, sleepOnset: Double, lastUse: Double?) async {
        // A Completed/Missed edit would outrank the times, so remove it first.
        await clearOverrides(goal, on: night)
        await record([
            Metric(id: Bedtime.onsetEditId(night), ownerId: data.ownerId, date: night, type: .phoneBeforeBed, source: .manual,
                   value: sleepOnset, detail: [MetricKind.key: MetricKind.sleepOnsetEdit]),
            Metric(id: Bedtime.lastUseEditId(night), ownerId: data.ownerId, date: night, type: .phoneBeforeBed, source: .manual,
                   value: lastUse ?? -1, detail: [MetricKind.key: MetricKind.lastUseEdit]),
        ])
    }

    func isEdited(_ goal: Goal, on day: DayKey) -> Bool {
        summary(goal, on: day)?.confidence == .manual
    }

    private func writeEdit(_ goal: Goal, _ day: DayKey, kind: String, value: Double) async {
        let metric = Metric(id: MetricKind.overrideId(goal.type, day), ownerId: data.ownerId, date: day, type: goal.type,
                            source: .manual, value: value, detail: [MetricKind.key: kind])
        await record([metric])
    }

    // MARK: Challenge

    func setChallenge(_ challenge: Challenge) async {
        var updated = challenge
        updated.updatedAt = .now
        let saved = updated
        await store.update { $0.challenge = saved }
        await reload()
        await loadChallengeHistory()
    }

    func removeChallenge() async {
        guard var challenge = data.challenge else { return }
        challenge.removed = true
        challenge.updatedAt = .now
        let removed = challenge
        await store.update { $0.challenge = removed }
        await reload()
    }

    /// Pulls results for the challenge's past days from the server (e.g. days recorded on the other device).
    func loadChallengeHistory() async {
        guard let challenge = data.activeChallenge, challenge.start <= today else { return }
        try? await engine.pullSummaries(from: challenge.start, through: min(challenge.end, today))
        await reload()
    }

    func challengeStats() -> ChallengeStats? {
        guard let challenge = data.activeChallenge else { return nil }
        let data = data
        // Workout minutes per day, from logged workouts (walks excluded, as for counting).
        var workoutMinutes: [DayKey: Double] = [:]
        for metric in data.metrics.values where metric.type == .workout
            && metric.detail?[MetricKind.key] == MetricKind.workout && WorkoutRules.counts(metric) {
            workoutMinutes[metric.date, default: 0] += metric.value
        }
        let oldestMetricDay = today.adding(days: -LocalStore.metricRetentionDays)

        return ChallengeStats.compute(challenge: challenge, goals: data.activeGoals) { goal, day in
            data.summary(goalId: goal.id, day: day)
        } dailyValue: { goal, day, summary in
            guard goal.type == .workout, goal.workoutMeasure != .exerciseMinutes else {
                return ChallengeStats.summaryValue(goal, summary)
            }
            // An edited minutes value is the day's minutes; an edited count says nothing about minutes.
            if summary.confidence == .manual, goal.workoutMeasure == .longestWorkout {
                return ChallengeStats.summaryValue(goal, summary)
            }
            // Raw workouts are only kept locally for a couple of months; skip older days rather than count them as 0.
            guard day >= oldestMetricDay else { return nil }
            return ChallengeStats.DailyValue(workoutMinutes[day] ?? 0)
        }
    }

    // MARK: Account

    func signIn(_ session: AuthSession) async {
        await auth?.setSession(session)
        self.session = session
        guard let userId = session.userId else { return }
        await store.adoptOwner(userId)
        await engine.setAPI(api)
        if data.profile == nil || data.profile?.id != userId {
            let name = session.email?.components(separatedBy: "@").first?.capitalized ?? "Me"
            await setDisplayName(name)
        }
        await refresh()
    }

    func setDisplayName(_ name: String) async {
        await store.update { data in
            let profile = UserProfile(id: data.ownerId, displayName: name)
            data.profile = profile
            data.enqueue(.profile(profile))
        }
        await engine.flush()
        await reload()
    }

    func signOut() async {
        await auth?.setSession(nil)
        session = nil
        await engine.setAPI(nil)
        await reload()
    }

    // MARK: Partners

    func createInvite() async -> Invite? {
        guard let api else { return nil }
        do {
            return try await api.createInvite(ownerName: data.profile?.displayName ?? "Partner")
        } catch {
            report(error)
            return nil
        }
    }

    func acceptInvite(code: String) async -> Bool {
        guard let api else { return false }
        do {
            _ = try await api.acceptInvite(code: code, viewerName: data.profile?.displayName ?? "Partner")
            await refreshPartners()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func refreshPartners() async {
        guard let api else { return }
        do {
            try await engine.refreshPartners()
            shares = try await api.shares()
        } catch {
            report(error)
        }
        await reload()
    }

    func remove(_ share: Share) async {
        guard let api else { return }
        do {
            try await api.delete(share)
            await refreshPartners()
        } catch {
            report(error)
        }
    }

    func applyPartnerUpdate(_ summary: DaySummary) async {
        await engine.applyPartnerUpdate(summary)
        await reload()
    }

    // MARK: Devices

    /// Settings and sign-in arriving from the other device.
    func applyRemote(session remoteSession: AuthSession?, goals: [Goal], recapMinutes: Int?, challenge: Challenge? = nil) async {
        if let challenge, challenge.updatedAt > (data.challenge?.updatedAt ?? .distantPast) {
            await store.update { $0.challenge = challenge }
        }
        if let remoteSession, remoteSession.userId != session?.userId || session == nil {
            await signIn(remoteSession)
        }
        // Goals from your own paired device are yours even if one side isn't signed in yet.
        let owner = data.ownerId
        let mine = goals.map { var goal = $0; goal.ownerId = owner; return goal }
        if !mine.isEmpty { await engine.merge(goals: mine) }
        if let recapMinutes, recapMinutes != data.preferences.recapMinutes {
            await setRecapMinutes(recapMinutes)
        }
        await reload()
    }

    private func report(_ error: Error) {
        if let authError = error as? AuthError, case .notSignedIn = authError {
            session = nil
            Task { await engine.setAPI(nil) }
        }
        // Network hiccups (offline, Wi-Fi switching, TLS failures) aren't worth an alert: the upload
        // queue keeps everything and the next refresh retries.
        if error is URLError {
            print("Sync will retry: \(error.localizedDescription)")
            return
        }
        errorMessage = error.localizedDescription
    }
}
