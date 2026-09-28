import Foundation

/// Typed calls to the Amplify backend's custom operations (see `backend/amplify/data/resource.ts`).
/// Reads take an `ownerId`: your own, or a partner's who has shared with you. The server checks the Share.
public struct GoalAPI: Sendable {
    public let client: GraphQLClient

    public init(client: GraphQLClient) {
        self.client = client
    }

    // MARK: Writes (owner only)

    public func put(_ metric: Metric) async throws {
        let wire = MetricWire(metric)
        _ = try await client.send("""
            mutation PutMetric($ownerId: String!, $sk: String!, $metricId: String!, $date: AWSDate!, $type: String!, $source: String!, $value: Float!, $recordedAt: AWSDateTime!, $detail: AWSJSON) {
              putMetric(ownerId: $ownerId, sk: $sk, metricId: $metricId, date: $date, type: $type, source: $source, value: $value, recordedAt: $recordedAt, detail: $detail) { ownerId sk }
            }
            """, variables: wire, field: "putMetric", as: Ack.self)
    }

    public func upsert(_ summary: DaySummary) async throws {
        _ = try await client.send("""
            mutation UpsertDaySummary($ownerId: String!, $sk: String!, $date: AWSDate!, $goalId: String!, $goalType: String!, $status: String!, $value: Float, $upperValue: Float, $confidence: String!, $changedAt: AWSDateTime!) {
              upsertDaySummary(ownerId: $ownerId, sk: $sk, date: $date, goalId: $goalId, goalType: $goalType, status: $status, value: $value, upperValue: $upperValue, confidence: $confidence, changedAt: $changedAt) { \(DaySummaryWire.selection) }
            }
            """, variables: DaySummaryWire(summary), field: "upsertDaySummary", as: DaySummaryWire.self)
    }

    public func upsert(_ goal: Goal) async throws {
        _ = try await client.send("""
            mutation UpsertGoal($ownerId: String!, $id: String!, $type: String!, $direction: String!, $target: Float!, $unit: String!, $active: Boolean!, $days: Int!, $workoutMeasure: String, $changedAt: AWSDateTime!) {
              upsertGoal(ownerId: $ownerId, id: $id, type: $type, direction: $direction, target: $target, unit: $unit, active: $active, days: $days, workoutMeasure: $workoutMeasure, changedAt: $changedAt) { ownerId id }
            }
            """, variables: GoalWire(goal), field: "upsertGoal", as: Ack.self)
    }

    public func put(_ profile: UserProfile) async throws {
        struct Vars: Encodable, Sendable { var ownerId, displayName, timeZone: String }
        _ = try await client.send("""
            mutation PutUser($ownerId: String!, $displayName: String!, $timeZone: String!) {
              putUser(ownerId: $ownerId, displayName: $displayName, timeZone: $timeZone) { ownerId }
            }
            """, variables: Vars(ownerId: profile.id, displayName: profile.displayName, timeZone: profile.timeZone),
            field: "putUser", as: Ack.self)
    }

    // MARK: Reads (owner or partner)

    public func goals(ownerId: String) async throws -> [Goal] {
        struct Vars: Encodable, Sendable { var ownerId: String }
        let wires = try await client.send("""
            query GoalsFor($ownerId: String!) { goalsFor(ownerId: $ownerId) { \(GoalWire.selection) } }
            """, variables: Vars(ownerId: ownerId), field: "goalsFor", as: [GoalWire].self) ?? []
        return wires.compactMap(\.model)
    }

    public func summaries(ownerId: String, from: DayKey, through to: DayKey) async throws -> [DaySummary] {
        let wires = try await client.send("""
            query DaySummariesFor($ownerId: String!, $from: String!, $to: String!) { daySummariesFor(ownerId: $ownerId, from: $from, to: $to) { \(DaySummaryWire.selection) } }
            """, variables: RangeVars(ownerId: ownerId, from: from, to: to), field: "daySummariesFor", as: [DaySummaryWire].self) ?? []
        return wires.compactMap(\.model)
    }

    public func metrics(ownerId: String, from: DayKey, through to: DayKey) async throws -> [Metric] {
        let wires = try await client.send("""
            query MetricsFor($ownerId: String!, $from: String!, $to: String!) { metricsFor(ownerId: $ownerId, from: $from, to: $to) { \(MetricWire.selection) } }
            """, variables: RangeVars(ownerId: ownerId, from: from, to: to), field: "metricsFor", as: [MetricWire].self) ?? []
        return wires.compactMap(\.model)
    }

    // MARK: Sharing

    public func createInvite(ownerName: String) async throws -> Invite {
        struct Vars: Encodable, Sendable { var ownerName: String }
        guard let invite = try await client.send("""
            mutation MakeInvite($ownerName: String!) { makeInvite(ownerName: $ownerName) { code ownerId expiresAt } }
            """, variables: Vars(ownerName: ownerName), field: "makeInvite", as: Invite.self)
        else { throw GraphQLError(message: "Couldn't create an invite.") }
        return invite
    }

    public func acceptInvite(code: String, viewerName: String) async throws -> Share {
        struct Vars: Encodable, Sendable { var code, viewerName: String }
        guard let share = try await client.send("""
            mutation AcceptInvite($code: String!, $viewerName: String!) { acceptInvite(code: $code, viewerName: $viewerName) { ownerId viewerId ownerName viewerName createdAt } }
            """, variables: Vars(code: code.uppercased().trimmingCharacters(in: .whitespaces), viewerName: viewerName),
            field: "acceptInvite", as: Share.self)
        else { throw GraphQLError(message: "That code didn't work.") }
        return share
    }

    /// Shares you own (people who can see you) and shares naming you (people you can see).
    public func shares() async throws -> [Share] {
        struct Page: Decodable, Sendable { var items: [Share] }
        return try await client.send("""
            query ListShares { listShares(limit: 100) { items { ownerId viewerId ownerName viewerName createdAt } } }
            """, variables: GraphQLClient.NoVariables(), field: "listShares", as: Page.self)?.items ?? []
    }

    public func delete(_ share: Share) async throws {
        struct Vars: Encodable, Sendable { var ownerId, viewerId: String }
        _ = try await client.send("""
            mutation DeleteShare($ownerId: String!, $viewerId: String!) { deleteShare(input: { ownerId: $ownerId, viewerId: $viewerId }) { ownerId } }
            """, variables: Vars(ownerId: share.ownerId, viewerId: share.viewerId), field: "deleteShare", as: Ack.self)
    }

    static let summarySubscription = """
        subscription OnDaySummaryUpserted($ownerId: String!) { onDaySummaryUpserted(ownerId: $ownerId) { \(DaySummaryWire.selection) } }
        """
}

private struct Ack: Decodable, Sendable {}

private struct RangeVars: Encodable, Sendable {
    var ownerId: String
    var from: String
    var to: String

    init(ownerId: String, from: DayKey, to: DayKey) {
        self.ownerId = ownerId
        self.from = from.rawValue
        self.to = to.rawValue
    }
}

// MARK: Wire formats

/// Enums travel as strings and `detail` as an AWSJSON string, so the schema doesn't need GraphQL enums.
struct MetricWire: Codable, Sendable {
    var ownerId, sk, metricId, date, type, source: String
    var value: Double
    var recordedAt: Date
    var detail: String?

    static let selection = "ownerId sk metricId date type source value recordedAt detail"

    init(_ m: Metric) {
        ownerId = m.ownerId
        sk = m.sortKey
        metricId = m.id
        date = m.date.rawValue
        type = m.type.rawValue
        source = m.source.rawValue
        value = m.value
        recordedAt = m.recordedAt
        detail = m.detail.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    var model: Metric? {
        guard let day = DayKey(rawValue: date), let type = GoalType(rawValue: type), let source = MetricSource(rawValue: source) else { return nil }
        let detail = detail.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        return Metric(id: metricId, ownerId: ownerId, date: day, type: type, source: source, value: value, recordedAt: recordedAt, detail: detail)
    }
}

struct DaySummaryWire: Codable, Sendable {
    var ownerId, sk, date, goalId, goalType, status, confidence: String
    var value, upperValue: Double?
    var changedAt: Date

    static let selection = "ownerId sk date goalId goalType status value upperValue confidence changedAt"

    init(_ s: DaySummary) {
        ownerId = s.ownerId
        sk = s.sortKey
        date = s.date.rawValue
        goalId = s.goalId
        goalType = s.goalType.rawValue
        status = s.status.rawValue
        confidence = s.confidence.rawValue
        value = s.value
        upperValue = s.upperValue
        changedAt = s.updatedAt
    }

    var model: DaySummary? {
        guard let day = DayKey(rawValue: date), let type = GoalType(rawValue: goalType),
              let status = DayStatus(rawValue: status), let confidence = Confidence(rawValue: confidence) else { return nil }
        return DaySummary(ownerId: ownerId, date: day, goalId: goalId, goalType: type, status: status,
                          value: value, upperValue: upperValue, confidence: confidence, updatedAt: changedAt)
    }
}

struct GoalWire: Codable, Sendable {
    var ownerId, id, type, direction, unit: String
    var target: Double
    var active: Bool
    var days: Int
    var workoutMeasure: String?
    var changedAt: Date

    static let selection = "ownerId id type direction target unit active days workoutMeasure changedAt"

    init(_ g: Goal) {
        ownerId = g.ownerId
        id = g.id
        type = g.type.rawValue
        direction = g.direction.rawValue
        unit = g.unit
        target = g.target
        active = g.active
        days = g.days.rawValue
        workoutMeasure = g.workoutMeasure?.rawValue
        changedAt = g.updatedAt
    }

    var model: Goal? {
        guard let type = GoalType(rawValue: type) else { return nil }
        return Goal(id: id, ownerId: ownerId, type: type, target: target, active: active, days: Weekdays(rawValue: days),
                    workoutMeasure: workoutMeasure.flatMap(WorkoutMeasure.init(rawValue:)), updatedAt: changedAt)
    }
}
