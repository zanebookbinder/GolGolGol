import CryptoKit
import Foundation
import Security

/// Cognito tokens for the signed-in user. The iPhone signs in and sends this to the Watch over
/// WatchConnectivity; each device then refreshes it on its own.
public struct AuthSession: Codable, Hashable, Sendable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(idToken: String, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// The Cognito `sub`, used as `ownerId` everywhere.
    public var userId: String? { claims["sub"] as? String }
    public var email: String? { claims["email"] as? String }

    public var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 5 * 60 }

    private var claims: [String: Any] {
        let parts = idToken.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

public enum AuthError: Error, LocalizedError {
    case notSignedIn
    case notConfigured
    case cognito(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in."
        case .notConfigured: "The app was built without a backend (amplify_outputs.json is missing)."
        case .cognito(let message): message
        }
    }
}

/// Stores the session in the Keychain. On iOS, pass the App Group as `accessGroup` so the monitor
/// extension can read it.
public struct KeychainSessionStore: Sendable {
    let service = "GoalTracker"
    let account = "session"
    let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() -> AuthSession? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func save(_ session: AuthSession?) {
        SecItemDelete(query as CFDictionary)
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        // Readable in the background (monitor extension, background refresh) after first unlock.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// Cognito hosted-UI sign-in (PKCE) and token refresh, over plain HTTPS so it works on watchOS too.
public actor CognitoAuth {
    public nonisolated let config: BackendConfig
    private let store: KeychainSessionStore
    private var session: AuthSession?
    private let urlSession: URLSession

    public init(config: BackendConfig, store: KeychainSessionStore, urlSession: URLSession = .shared) {
        self.config = config
        self.store = store
        self.urlSession = urlSession
        self.session = store.load()
    }

    public var currentSession: AuthSession? { session }

    public func setSession(_ session: AuthSession?) {
        self.session = session
        store.save(session)
    }

    /// A valid ID token, refreshing it first if it's about to expire.
    public func idToken() async throws -> String {
        guard var session = session ?? store.load() else { throw AuthError.notSignedIn }
        if session.needsRefresh {
            session = try await refresh(session)
            setSession(session)
        }
        return session.idToken
    }

    // MARK: Hosted UI (PKCE)

    public struct AuthorizationRequest: Sendable {
        public var url: URL
        public var verifier: String
        public var state: String
    }

    /// `provider` is "SignInWithApple" for Sign in with Apple, or nil for Cognito's own email sign-in page.
    public nonisolated func authorizationRequest(provider: String?) throws -> AuthorizationRequest {
        guard let domain = config.oauthDomain else { throw AuthError.notConfigured }
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)
        var components = URLComponents(string: "https://\(domain)/oauth2/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: config.userPoolClientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "scope", value: "openid email profile aws.cognito.signin.user.admin"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ] + (provider.map { [.init(name: "identity_provider", value: $0)] } ?? [])
        return AuthorizationRequest(url: components.url!, verifier: verifier, state: state)
    }

    /// Completes sign-in from the redirect URL the hosted UI returned.
    public func completeSignIn(callback: URL, request: AuthorizationRequest) async throws -> AuthSession {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error_description" || $0.name == "error" })?.value {
            throw AuthError.cognito(error)
        }
        guard items.first(where: { $0.name == "state" })?.value == request.state,
              let code = items.first(where: { $0.name == "code" })?.value,
              let domain = config.oauthDomain else { throw AuthError.cognito("Sign-in was interrupted.") }

        var urlRequest = URLRequest(url: URL(string: "https://\(domain)/oauth2/token")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "client_id", value: config.userPoolClientId),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "code_verifier", value: request.verifier),
        ]
        urlRequest.httpBody = Data(form.percentEncodedQuery!.utf8)

        struct TokenResponse: Decodable {
            var id_token: String
            var access_token: String
            var refresh_token: String
            var expires_in: Double
        }
        let (data, response) = try await urlSession.data(for: urlRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.cognito(String(decoding: data, as: UTF8.self))
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        let session = AuthSession(idToken: tokens.id_token, accessToken: tokens.access_token,
                                  refreshToken: tokens.refresh_token, expiresAt: .now.addingTimeInterval(tokens.expires_in))
        setSession(session)
        return session
    }

    // MARK: Refresh

    private func refresh(_ session: AuthSession) async throws -> AuthSession {
        var request = URLRequest(url: URL(string: "https://cognito-idp.\(config.region).amazonaws.com/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.InitiateAuth", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "ClientId": config.userPoolClientId,
            "AuthParameters": ["REFRESH_TOKEN": session.refreshToken],
        ])

        struct RefreshResponse: Decodable {
            struct Result: Decodable {
                var IdToken: String
                var AccessToken: String
                var ExpiresIn: Double
            }
            var AuthenticationResult: Result
        }
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if String(decoding: data, as: UTF8.self).contains("NotAuthorizedException") {
                setSession(nil)
                throw AuthError.notSignedIn
            }
            throw AuthError.cognito(String(decoding: data, as: UTF8.self))
        }
        let result = try JSONDecoder().decode(RefreshResponse.self, from: data).AuthenticationResult
        return AuthSession(idToken: result.IdToken, accessToken: result.AccessToken,
                           refreshToken: session.refreshToken, expiresAt: .now.addingTimeInterval(result.ExpiresIn))
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
