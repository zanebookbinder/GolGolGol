import Foundation

/// The parts of Amplify Gen 2's `amplify_outputs.json` the apps use.
public struct BackendConfig: Sendable, Equatable {
    public var region: String
    public var userPoolClientId: String
    /// Cognito hosted UI domain, e.g. `abc123.auth.us-east-1.amazoncognito.com`.
    public var oauthDomain: String?
    public var redirectURI: String
    public var graphQLURL: URL
    /// False until the backend is deployed with Sign in with Apple (SIWA=1).
    public var supportsSignInWithApple: Bool

    public init(region: String, userPoolClientId: String, oauthDomain: String?, redirectURI: String, graphQLURL: URL,
                supportsSignInWithApple: Bool = false) {
        self.region = region
        self.userPoolClientId = userPoolClientId
        self.oauthDomain = oauthDomain
        self.redirectURI = redirectURI
        self.graphQLURL = graphQLURL
        self.supportsSignInWithApple = supportsSignInWithApple
    }

    public init(outputsJSON data: Data) throws {
        struct Outputs: Decodable {
            struct Auth: Decodable {
                struct OAuth: Decodable {
                    var domain: String
                    var redirect_sign_in_uri: [String]
                    var identity_providers: [String]?
                }
                var aws_region: String
                var user_pool_client_id: String
                var oauth: OAuth?
            }
            struct DataSection: Decodable {
                var url: URL
            }
            var auth: Auth
            var data: DataSection
        }
        let outputs = try JSONDecoder().decode(Outputs.self, from: data)
        self.init(
            region: outputs.auth.aws_region,
            userPoolClientId: outputs.auth.user_pool_client_id,
            oauthDomain: outputs.auth.oauth?.domain,
            redirectURI: outputs.auth.oauth?.redirect_sign_in_uri.first ?? "goaltracker://auth/",
            graphQLURL: outputs.data.url,
            supportsSignInWithApple: outputs.auth.oauth?.identity_providers?.contains("SIGN_IN_WITH_APPLE") ?? false
        )
    }

    /// Loads `amplify_outputs.json` from the bundle, or nil when the app was built without a backend
    /// (it then runs local-only).
    public static func load(from bundle: Bundle = .main) -> BackendConfig? {
        guard let url = bundle.url(forResource: "amplify_outputs", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? BackendConfig(outputsJSON: data)
    }
}

enum GoalJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(string, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }()
}
