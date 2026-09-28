import Foundation

struct LoggedEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case monitoring, threshold, snapshot, snapshotRejected, info, error
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var message: String
}

/// Recent screen time events (threshold crossings, snapshots, OCR failures), shown in Settings so
/// misreads are easy to spot. Shared by the app, the monitor extension, and the snapshot intent.
enum EventLog {
    private static let key = "eventLog"
    private static let limit = 200

    static func append(_ kind: LoggedEvent.Kind, _ message: String) {
        var events = read()
        events.append(LoggedEvent(date: .now, kind: kind, message: message))
        if let data = try? JSONEncoder().encode(events.suffix(limit)) {
            AppGroup.defaults.set(data, forKey: key)
        }
    }

    static func read() -> [LoggedEvent] {
        guard let data = AppGroup.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LoggedEvent].self, from: data)) ?? []
    }

    static func clear() {
        AppGroup.defaults.removeObject(forKey: key)
    }
}
