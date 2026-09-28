import Foundation

public struct GraphQLError: Error, LocalizedError, Decodable, Sendable {
    public var message: String
    public var errorType: String?

    public var errorDescription: String? { message }

    public var isUnauthorized: Bool {
        errorType == "Unauthorized" || message.localizedCaseInsensitiveContains("not authorized")
    }
}

/// Minimal AppSync client: POSTs a query with the user's Cognito ID token and decodes one field of `data`.
public struct GraphQLClient: Sendable {
    public let url: URL
    public let auth: CognitoAuth
    let urlSession: URLSession

    public init(url: URL, auth: CognitoAuth, urlSession: URLSession = .shared) {
        self.url = url
        self.auth = auth
        self.urlSession = urlSession
    }

    private struct Body<Variables: Encodable>: Encodable {
        var query: String
        var variables: Variables
    }

    private struct Response<T: Decodable>: Decodable {
        var data: [String: T?]?
        var errors: [GraphQLError]?
    }

    public struct NoVariables: Encodable, Sendable {
        public init() {}
    }

    /// Runs `query` and returns the value of the `field` it selects (nil if AppSync returned null).
    public func send<T: Decodable & Sendable, V: Encodable & Sendable>(_ query: String, variables: V, field: String, as type: T.Type = T.self) async throws -> T? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try await auth.idToken(), forHTTPHeaderField: "Authorization")
        request.httpBody = try GoalJSON.encoder.encode(Body(query: query, variables: variables))

        let (data, response) = try await urlSession.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 401 {
            throw AuthError.notSignedIn
        }
        let decoded = try GoalJSON.decoder.decode(Response<T>.self, from: data)
        if let error = decoded.errors?.first { throw error }
        return decoded.data?[field] ?? nil
    }
}
