import Foundation
import GoalKit
import HealthKit

/// Reads steps, exercise minutes, workouts, and sleep from HealthKit and turns them into Metrics.
/// Metric ids are deterministic, so collecting the same day again overwrites rather than duplicates.
final class HealthCollector: @unchecked Sendable {
    static let shared = HealthCollector()

    let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []

    private let stepType = HKQuantityType(.stepCount)
    private let exerciseType = HKQuantityType(.appleExerciseTime)
    private let energyType = HKQuantityType(.activeEnergyBurned)
    private let heartRateType = HKQuantityType(.heartRate)
    private let sleepType = HKCategoryType(.sleepAnalysis)
    private let workoutType = HKObjectType.workoutType()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(
            toShare: [],
            read: [stepType, exerciseType, energyType, heartRateType, sleepType, workoutType]
        )
    }

    /// Everything HealthKit knows about `day`. Each kind is read separately, so one failing or empty
    /// query (e.g. no exercise minutes yet) doesn't drop the others.
    func collect(day: DayKey, ownerId: String) async -> [Metric] {
        guard isAvailable else { return [] }
        async let steps = read("steps", day) { try await self.hourlySteps(day: day, ownerId: ownerId) }
        async let exercise = read("exercise", day) { try await self.exerciseMinutes(day: day, ownerId: ownerId) }
        async let workouts = read("workouts", day) { try await self.workouts(day: day, ownerId: ownerId) }
        async let wakeup = read("sleep", day) { try await self.wakeup(day: day, ownerId: ownerId) }
        return await steps + exercise + workouts + wakeup
    }

    /// Runs one query. "No data" is an empty result, not an error; anything else (e.g. the device is
    /// locked) is logged and retried on the next refresh.
    private func read(_ name: String, _ day: DayKey, _ query: () async throws -> [Metric]) async -> [Metric] {
        let line: String
        var metrics: [Metric] = []
        do {
            metrics = try await query()
            line = "\(name): \(metrics.count) readings" + (name == "steps" ? " (\(Int(metrics.reduce(0) { $0 + $1.value })) steps)" : "")
        } catch let error as HKError where error.code == .errorNoData {
            line = "\(name): no data"
        } catch {
            line = "\(name): \(error.localizedDescription)"
        }
        record("\(day.rawValue) \(line)")
        return metrics
    }

    // MARK: Diagnostics

    private let lock = NSLock()
    private var log: [String] = []

    /// What the last reads returned, shown in Settings to tell "no permission" from "no data".
    var diagnostics: [String] {
        lock.withLock { log }
    }

    private func record(_ line: String) {
        print("HealthKit \(line)")
        lock.withLock {
            log.append("\(Date.now.formatted(date: .omitted, time: .standard)) \(line)")
            log = Array(log.suffix(16))
        }
    }

    /// Whether the permission prompt still needs to be shown. HealthKit never reveals whether read
    /// access was granted; a declined read just returns no data.
    func authorizationRequestStatus() async -> String {
        guard isAvailable else { return "Health data unavailable on this device" }
        do {
            let status = try await store.statusForAuthorizationRequest(
                toShare: [], read: [stepType, exerciseType, energyType, heartRateType, sleepType, workoutType])
            return switch status {
            case .shouldRequest: "Not asked yet"
            case .unnecessary: "Asked (check Health settings if data is missing)"
            default: "Unknown"
            }
        } catch {
            return error.localizedDescription
        }
    }

    /// Calls `onChange` whenever HealthKit gets new steps, workouts, or sleep, including in the
    /// background (HealthKit wakes the app).
    func observe(onChange: @escaping @Sendable () async -> Void) {
        guard isAvailable, observers.isEmpty else { return }
        let types: [(HKSampleType, HKUpdateFrequency)] = [
            (stepType, .hourly), (exerciseType, .hourly), (workoutType, .immediate), (sleepType, .immediate),
        ]
        for (type, frequency) in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task {
                    await onChange()
                    completion()
                }
            }
            store.execute(query)
            observers.append(query)
            store.enableBackgroundDelivery(for: type, frequency: frequency) { _, error in
                if let error { print("Background delivery for \(type): \(error)") }
            }
        }
    }

    // MARK: Queries

    private func dayPredicate(_ day: DayKey) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: day.start(), end: day.end(), options: .strictStartDate)
    }

    /// Hourly step buckets. The statistics query de-duplicates iPhone and Watch samples.
    private func hourlySteps(day: DayKey, ownerId: String) async throws -> [Metric] {
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: stepType, predicate: dayPredicate(day)),
            options: .cumulativeSum,
            anchorDate: day.start(),
            intervalComponents: DateComponents(hour: 1)
        )
        let collection = try await query.result(for: store)
        var metrics: [Metric] = []
        collection.enumerateStatistics(from: day.start(), to: min(day.end(), .now)) { statistics, _ in
            guard let sum = statistics.sumQuantity() else { return }
            let hour = Calendar.current.component(.hour, from: statistics.startDate)
            metrics.append(Metric(
                id: "steps:\(day.rawValue)T\(String(format: "%02d", hour))", ownerId: ownerId, date: day, type: .steps,
                source: .healthKit, value: sum.doubleValue(for: .count()), recordedAt: statistics.endDate,
                detail: [MetricKind.key: MetricKind.hourlySteps, "hour": String(hour)]
            ))
        }
        return metrics
    }

    private func exerciseMinutes(day: DayKey, ownerId: String) async throws -> [Metric] {
        let query = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: exerciseType, predicate: dayPredicate(day)),
            options: .cumulativeSum
        )
        guard let sum = try await query.result(for: store)?.sumQuantity() else { return [] }
        return [Metric(id: "exercise:\(day.rawValue)", ownerId: ownerId, date: day, type: .workout, source: .healthKit,
                       value: sum.doubleValue(for: .minute()), detail: [MetricKind.key: MetricKind.exerciseMinutes])]
    }

    private func workouts(day: DayKey, ownerId: String) async throws -> [Metric] {
        let query = HKSampleQueryDescriptor(
            predicates: [.workout(dayPredicate(day))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        var metrics: [Metric] = []
        for workout in try await query.result(for: store) {
            var detail = [
                MetricKind.key: MetricKind.workout,
                "activity": workout.workoutActivityType.name,
                "activityType": String(workout.workoutActivityType.rawValue),
                "start": workout.startDate.ISO8601Format(),
                "end": workout.endDate.ISO8601Format(),
            ]
            if let kcal = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                detail["calories"] = String(Int(kcal))
            }
            if let bpm = workout.statistics(for: heartRateType)?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) {
                detail["avgHeartRate"] = String(Int(bpm))
            }
            metrics.append(Metric(id: "workout:\(workout.uuid.uuidString)", ownerId: ownerId, date: day, type: .workout,
                                  source: .healthKit, value: workout.duration / 60, recordedAt: workout.endDate, detail: detail))
        }
        return metrics
    }

    /// The morning's final wake time, from asleep samples (not in-bed or awake).
    private func wakeup(day: DayKey, ownerId: String) async throws -> [Metric] {
        let window = WakeupDetector.searchWindow(for: day)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: HKQuery.predicateForSamples(withStart: window.start, end: window.end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let intervals = try await query.result(for: store)
            .filter { asleep.contains($0.value) }
            .map { SleepInterval(start: $0.startDate, end: $0.endDate) }
        guard let wake = WakeupDetector.wakeTime(from: intervals, on: day) else { return [] }
        return [Metric(id: "wakeup:\(day.rawValue)", ownerId: ownerId, date: day, type: .wakeup, source: .healthKit,
                       value: WakeupDetector.minutesAfterMidnight(wake, on: day), recordedAt: wake,
                       detail: ["wokeAt": wake.ISO8601Format()])]
    }
}

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .hiking: "Hiking"
        case .yoga: "Yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength"
        case .highIntensityIntervalTraining: "HIIT"
        case .elliptical: "Elliptical"
        case .rowing: "Rowing"
        case .dance, .cardioDance: "Dance"
        case .coreTraining: "Core"
        case .pilates: "Pilates"
        default: "Workout"
        }
    }
}
