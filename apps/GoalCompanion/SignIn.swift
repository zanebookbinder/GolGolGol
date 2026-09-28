import AuthenticationServices
import GoalKit
import SwiftUI

/// Runs the Cognito hosted UI in an ASWebAuthenticationSession and hands the session to the model
/// (which also sends it to the Watch).
@MainActor
final class SignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SignInCoordinator()
    private var session: ASWebAuthenticationSession?

    enum Provider {
        case apple, email

        var cognitoName: String? { self == .apple ? "SignInWithApple" : nil }
    }

    func signIn(with provider: Provider, model: AppModel) async throws {
        guard let auth = model.auth else { throw AuthError.notConfigured }
        let request = try auth.authorizationRequest(provider: provider.cognitoName)
        let scheme = URL(string: auth.config.redirectURI)?.scheme ?? "goaltracker"

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: request.url, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? AuthError.cognito("Sign-in was cancelled."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            session.start()
        }
        let authSession = try await auth.completeSignIn(callback: callback, request: request)
        await model.signIn(authSession)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

struct SignInButtons: View {
    @Environment(AppModel.self) private var model
    @State private var working = false

    var body: some View {
        VStack(spacing: 12) {
            if model.config?.supportsSignInWithApple == true {
                SignInWithAppleButton(.signIn) { _ in } onCompletion: { _ in }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                    .allowsHitTesting(false)
                    .overlay {
                        // Apple's button for looks; Cognito's hosted UI does the actual Sign in with Apple.
                        Color.clear.contentShape(Rectangle()).onTapGesture { run(.apple) }
                    }
                Button("Sign in with email") { run(.email) }
                    .buttonStyle(.bordered)
            } else {
                Button { run(.email) } label: {
                    Text("Sign in or create account").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .disabled(working || !model.isBackendConfigured)
        .overlay { if working { ProgressView() } }
    }

    private func run(_ provider: SignInCoordinator.Provider) {
        working = true
        Task {
            defer { working = false }
            do {
                try await SignInCoordinator.shared.signIn(with: provider, model: model)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // User closed the sheet.
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
