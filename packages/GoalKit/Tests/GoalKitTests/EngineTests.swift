import Foundation
import Testing
@testable import GoalKit

struct EngineTests {
    func makeEngine() -> (GoalEngine, LocalStore) {
        let url = FileManager.default.temporaryDirectory.appending(path: "goalkit-\(UUID().uuidString).json")
        let store = LocalStore(url: url)
        return (GoalEngine(store: store, api: nil), store)
    }

    @Test func recordEvaluatesAndQueues() async {
        let (engine, store) = makeEngine()
        await engine.ensureGoals()
        let today = DayKey.today()
        let steps = Metric(id: "steps:1", ownerId: "x", date: today, type: .steps, source: .healthKit, value: 12_000,
                           detail: [MetricKind.key: MetricKind.hourlySteps])
        let changed = await engine.record([steps])
        #expect(changed.contains { $0.goalType == .steps && $0.status == .hit })

        let data = await store.data
        #expect(data.metrics.values.first?.ownerId == LocalStore.localOwnerId)
        #expect(data.pending.keys.contains { $0.hasPrefix("m#") })
        #expect(data.goals.count == GoalType.allCases.count)

        // Recording the same reading again changes nothing.
        #expect(await engine.record([steps]).isEmpty)
    }

    @Test func storePersistsAndAdoptsOwner() async {
        let (engine, store) = makeEngine()
        await engine.ensureGoals()
        await store.adoptOwner("user-1")
        let reloaded = LocalStore.read(from: store.url)
        #expect(reloaded?.ownerId == "user-1")
        #expect(reloaded?.goals.allSatisfy { $0.ownerId == "user-1" } == true)
    }

    @Test func mergeKeepsNewerGoal() async {
        let (engine, store) = makeEngine()
        await engine.ensureGoals()
        var steps = await store.data.goals.first { $0.type == .steps }!
        steps.target = 5_000
        steps.updatedAt = .now.addingTimeInterval(60)
        await engine.merge(goals: [steps])
        #expect(await store.data.goals.first { $0.type == .steps }?.target == 5_000)

        steps.target = 1
        steps.updatedAt = .distantPast
        await engine.merge(goals: [steps])
        #expect(await store.data.goals.first { $0.type == .steps }?.target == 5_000)
    }

    @Test func recapAnswerClearsQuestionAfterGoalIdsMerge() async {
        let (engine, store) = makeEngine()
        await engine.ensureGoals()
        let yesterday = DayKey.today().adding(days: -1)
        await engine.reevaluate(days: [yesterday])
        #expect(GoalEvaluator.questions(for: await store.data.summaries(for: yesterday)).contains(.overeating))

        // A leftover copy of the same goal (old random id) arrives from the server and is newer.
        var theirs = await store.data.goals.first { $0.type == .overeating }!
        theirs.id = "other-device-id"
        theirs.updatedAt = .now.addingTimeInterval(60)
        await engine.merge(goals: [theirs])
        let data = await store.data
        #expect(data.goals.filter { $0.type == .overeating }.map(\.id) == ["overeating"], "Still one goal, with the canonical id")

        let answer = Metric(id: "overeating:answer:\(yesterday.rawValue)", ownerId: data.ownerId, date: yesterday,
                            type: .overeating, source: .manual, value: 0)
        await engine.record([answer])
        let questions = GoalEvaluator.questions(for: await store.data.summaries(for: yesterday))
        #expect(!questions.contains(.overeating))
    }

    @Test func migratesDuplicateGoalCopiesToOnePerType() throws {
        // What early builds left on the devices: three copies of the pickups goal, results split between them.
        let day = DayKey(rawValue: "2026-09-28")!
        var data = StoreData()
        data.ownerId = "u"
        let current = Goal(id: "54F1", ownerId: "u", type: .pickups, target: 60, updatedAt: Date(timeIntervalSince1970: 3))
        data.goals = [
            Goal(id: "3D2F", ownerId: "u", type: .pickups, target: 50, updatedAt: Date(timeIntervalSince1970: 1)),
            current,
            Goal(id: "3E2E", ownerId: "u", type: .pickups, target: 40, updatedAt: Date(timeIntervalSince1970: 2)),
        ]
        for (id, status, time) in [("3D2F", DayStatus.pending, 9.0), ("54F1", .missed, 5.0), ("3E2E", .pending, 8.0)] {
            let s = DaySummary(ownerId: "u", date: day, goalId: id, goalType: .pickups, status: status, value: nil,
                               confidence: .exact, updatedAt: Date(timeIntervalSince1970: time))
            data.summaries[s.sortKey] = s
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "migrate-\(UUID()).json")
        try GoalJSON.encoder.encode(data).write(to: url)

        let migrated = try #require(LocalStore.read(from: url).map { stored -> StoreData in
            var copy = stored
            _ = copy.canonicalizeGoals()
            return copy
        })
        #expect(migrated.goals.map(\.id) == ["pickups"])
        #expect(migrated.goals.first?.target == 60, "Keeps the most recently changed copy's settings")
        #expect(migrated.summaries.count == 1)
        #expect(migrated.summary(goalId: "pickups", day: day)?.status == .missed, "Keeps the current goal's result")
        #expect(migrated.pending.keys.contains("g#pickups"), "Re-uploads under the canonical id")
    }

    @Test func changingWorkoutMeasureReevaluatesToday() async {
        let (engine, store) = makeEngine()
        await engine.ensureGoals()
        var workout = await store.data.goals.first { $0.type == .workout }!
        workout.workoutMeasure = .longestWorkout
        workout.target = 30
        await engine.save(workout)

        let run = Metric(id: "workout:run", ownerId: "x", date: .today(), type: .workout, source: .healthKit, value: 12,
                         detail: [MetricKind.key: MetricKind.workout, "activityType": "37", "activity": "Running"])
        await engine.record([run])
        #expect(await store.data.summary(goalId: workout.id, day: .today())?.value == 12)

        workout.workoutMeasure = .workoutCount
        workout.target = 1
        await engine.save(workout)
        let summary = await store.data.summary(goalId: workout.id, day: .today())
        #expect(summary?.status == .hit && summary?.value == 1)
    }

    @Test func staleSummariesOfRemovedGoalsAreIgnored() async {
        let (engine, store) = makeEngine()
        await engine.ensureGoals()
        let day = DayKey.today().adding(days: -1)
        await store.update { data in
            let stale = DaySummary(ownerId: data.ownerId, date: day, goalId: "gone", goalType: .overeating,
                                   status: .pending, value: nil, confidence: .selfReported)
            data.summaries[stale.sortKey] = stale
        }
        #expect(await !store.data.summaries(for: day).contains { $0.goalId == "gone" })
    }

    @Test func inboxRoundTrip() {
        let inbox = MetricInbox(url: FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString).json"))
        let metric = Metric(id: "threshold:30", ownerId: "u", date: .today(), type: .screenTime, source: .threshold, value: 30)
        inbox.append([metric])
        inbox.append([metric])
        #expect(inbox.drain().count == 2)
        #expect(inbox.drain().isEmpty)
    }

    @Test func wireRoundTrip() throws {
        let metric = Metric(id: "workout:abc", ownerId: "u", date: DayKey(rawValue: "2026-09-28")!, type: .workout, source: .healthKit,
                            value: 42, recordedAt: Date(timeIntervalSince1970: 1_790_000_000.5), detail: [MetricKind.key: MetricKind.workout, "activity": "running"])
        let data = try GoalJSON.encoder.encode(MetricWire(metric))
        let decoded = try GoalJSON.decoder.decode(MetricWire.self, from: data).model
        #expect(decoded == metric)
        #expect(MetricWire(metric).sk == "2026-09-28#workout#workout:abc")
    }

    @Test func snapshotValidationRejectsBackwardValues() {
        let day = DayKey(rawValue: "2026-09-28")!
        let earlier = SnapshotValidator.metrics(for: SnapshotReading(screenTimeMinutes: 100, pickups: 50, day: nil), day: day, ownerId: "u")
        #expect(throws: SnapshotValidationError.self) {
            try SnapshotValidator.validate(SnapshotReading(screenTimeMinutes: 90, pickups: 55, day: nil), day: day, existing: earlier)
        }
        #expect(throws: Never.self) {
            try SnapshotValidator.validate(SnapshotReading(screenTimeMinutes: 110, pickups: 55, day: nil), day: day, existing: earlier)
        }
    }

    @Test func backendConfigParsesAmplifyOutputs() throws {
        let json = """
        {"version":"1.3","auth":{"aws_region":"us-east-1","user_pool_id":"p","user_pool_client_id":"c",
          "oauth":{"domain":"x.auth.us-east-1.amazoncognito.com","redirect_sign_in_uri":["goaltracker://auth/"]}},
         "data":{"url":"https://abc.appsync-api.us-east-1.amazonaws.com/graphql","aws_region":"us-east-1"}}
        """
        let config = try BackendConfig(outputsJSON: Data(json.utf8))
        #expect(config.userPoolClientId == "c")
        #expect(config.oauthDomain == "x.auth.us-east-1.amazoncognito.com")
    }
}
