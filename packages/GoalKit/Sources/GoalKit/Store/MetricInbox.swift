import Foundation

/// A tiny append-only file for extensions (the DeviceActivity monitor has a few MB of memory), so they
/// never load the full store. The app drains it into `GoalEngine` on launch and in the background.
public struct MetricInbox: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ metrics: [Metric]) {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(writingItemAt: url, options: [], error: &error) { url in
            var existing = (try? Data(contentsOf: url)).flatMap { try? GoalJSON.decoder.decode([Metric].self, from: $0) } ?? []
            existing.append(contentsOf: metrics)
            try? GoalJSON.encoder.encode(existing).write(to: url, options: .atomic)
        }
    }

    /// Returns and clears everything in the inbox.
    public func drain() -> [Metric] {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var drained: [Metric] = []
        coordinator.coordinate(writingItemAt: url, options: [], error: &error) { url in
            drained = (try? Data(contentsOf: url)).flatMap { try? GoalJSON.decoder.decode([Metric].self, from: $0) } ?? []
            try? FileManager.default.removeItem(at: url)
        }
        return drained
    }
}
