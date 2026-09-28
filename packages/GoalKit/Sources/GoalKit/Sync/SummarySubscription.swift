import Foundation

/// Live DaySummary updates for one owner over AppSync's real-time WebSocket protocol.
///
/// Use on iOS. watchOS only allows WebSockets during audio streaming, so the Watch polls instead.
public struct SummarySubscription: Sendable {
    public let client: GraphQLClient

    public init(client: GraphQLClient) {
        self.client = client
    }

    public func updates(ownerId: String) -> AsyncThrowingStream<DaySummary, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(ownerId: ownerId, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(ownerId: String, continuation: AsyncThrowingStream<DaySummary, Error>.Continuation) async throws {
        let token = try await client.auth.idToken()
        let host = client.url.host()!
        let authorization = ["host": host, "Authorization": token]

        var components = URLComponents(url: client.url, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.host = host.replacingOccurrences(of: "appsync-api", with: "appsync-realtime-api")
        components.queryItems = [
            .init(name: "header", value: try JSONSerialization.data(withJSONObject: authorization).base64EncodedString()),
            .init(name: "payload", value: Data("{}".utf8).base64EncodedString()),
        ]
        let socket = URLSession.shared.webSocketTask(with: components.url!, protocols: ["graphql-ws"])
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        try await socket.send(.string(#"{"type":"connection_init"}"#))

        let data = try JSONSerialization.data(withJSONObject: [
            "query": GoalAPI.summarySubscription,
            "variables": ["ownerId": ownerId],
        ])
        let start: [String: Any] = [
            "id": UUID().uuidString,
            "type": "start",
            "payload": [
                "data": String(decoding: data, as: UTF8.self),
                "extensions": ["authorization": authorization],
            ],
        ]
        var started = false

        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "connection_ack" where !started:
                started = true
                let startData = try JSONSerialization.data(withJSONObject: start)
                try await socket.send(.string(String(decoding: startData, as: UTF8.self)))
            case "data":
                guard let payload = json["payload"] as? [String: Any],
                      let dataField = payload["data"] as? [String: Any],
                      let item = dataField["onDaySummaryUpserted"] else { continue }
                let itemData = try JSONSerialization.data(withJSONObject: item)
                if let summary = try GoalJSON.decoder.decode(DaySummaryWire.self, from: itemData).model {
                    continuation.yield(summary)
                }
            case "error", "connection_error":
                throw GraphQLError(message: "Subscription error: \(text)")
            default:
                break // "ka" keep-alives, "start_ack"
            }
        }
    }
}
