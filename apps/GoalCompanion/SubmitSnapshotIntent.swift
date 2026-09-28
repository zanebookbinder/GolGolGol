import AppIntents
import GoalKit

enum SnapshotDayOption: String, AppEnum {
    case today, yesterday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Day"
    static let caseDisplayRepresentations: [SnapshotDayOption: DisplayRepresentation] = [
        .today: "Today",
        .yesterday: "Yesterday",
    ]
}

/// Takes the OCR text from the Snapshot shortcut, parses and validates it, and records it with
/// source `snapshot`. A snapshot overrides the threshold range and any self-reported pickups.
struct SubmitSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Submit Screen Time Snapshot"
    static let description = IntentDescription("Reads screen time and pickups from the Snapshot screen's text and saves them.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Day", default: .today)
    var day: SnapshotDayOption

    static var parameterSummary: some ParameterSummary {
        Summary("Submit snapshot from \(\.$text) for \(\.$day)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = AppModel.shared
        await model.start()

        let reading: SnapshotReading
        do {
            reading = try SnapshotParser.parse(text)
        } catch {
            EventLog.append(.snapshotRejected, "Couldn't read: \(text.prefix(120))")
            throw error
        }

        let today = DayKey.today()
        // The report prints its day; trust it over the parameter when OCR read it.
        let targetDay = reading.day.flatMap(DayKey.init(rawValue:)) ?? (day == .yesterday ? today.adding(days: -1) : today)
        do {
            try SnapshotValidator.validate(reading, day: targetDay, existing: Array(model.data.metrics.values))
        } catch {
            EventLog.append(.snapshotRejected, error.localizedDescription)
            throw error
        }

        await model.record(SnapshotValidator.metrics(for: reading, day: targetDay, ownerId: model.data.ownerId))
        try? await model.engine.sync(days: [targetDay])
        await model.reload()

        let summary = "\(GoalFormat.duration(minutes: Double(reading.screenTimeMinutes))), \(reading.pickups.map { "\($0) pickups" } ?? "pickups unreadable")"
        EventLog.append(.snapshot, "\(targetDay.rawValue): \(summary)")
        // Close the Snapshot screen now that it's been read, so a later snapshot never reuses it.
        NotificationCenter.default.post(name: .snapshotSubmitted, object: nil)
        // No dialog: the shortcut finishes quietly.
        return .result(value: summary)
    }
}

extension SnapshotParseError: @retroactive CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource { "\(description)" }
}

struct GoalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SubmitSnapshotIntent(),
            phrases: ["Submit a \(.applicationName) snapshot"],
            shortTitle: "Submit Snapshot",
            systemImageName: "camera.viewfinder"
        )
    }
}

extension Notification.Name {
    /// Posted when a snapshot's numbers have been saved; the app closes the Snapshot screen.
    static let snapshotSubmitted = Notification.Name("snapshotSubmitted")
}
