import Foundation
import GoalKit
import WatchConnectivity

/// The WatchConnectivity fast path. The backend is the source of truth; this only speeds things up:
/// - the iPhone hands its sign-in session to the Watch (Keychain items don't cross devices);
/// - both sides share goals and the recap time, so they stay in step even without a backend;
/// - the iPhone pushes screen time readings straight to the Watch when both are reachable.
final class DeviceLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = DeviceLink()

    private enum Key {
        static let session = "session"
        static let goals = "goals"
        static let recapMinutes = "recapMinutes"
        static let metrics = "metrics"
        static let alert = "alert"
        static let challenge = "challenge"
    }

    private var lastContext: Data?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var isPaired: Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        #if os(iOS)
        return WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
        #else
        return true
        #endif
    }

    /// Sends settings (and on iOS, the session) if they changed since the last send.
    @MainActor func push(_ data: StoreData, session: AuthSession?) {
        guard isPaired else { return }
        var context: [String: Any] = [Key.recapMinutes: data.preferences.recapMinutes]
        context[Key.goals] = try? JSONEncoder().encode(data.goals)
        context[Key.challenge] = data.challenge.flatMap { try? JSONEncoder().encode($0) }
        #if os(iOS)
        context[Key.session] = session.flatMap { try? JSONEncoder().encode($0) }
        #endif
        let fingerprint = try? NSKeyedArchiver.archivedData(withRootObject: context as NSDictionary, requiringSecureCoding: false)
        guard fingerprint != lastContext else { return }
        do {
            try WCSession.default.updateApplicationContext(context)
            lastContext = fingerprint
        } catch {
            print("updateApplicationContext failed: \(error)")
        }
    }

    func send(_ metrics: [Metric]) {
        guard isPaired, !metrics.isEmpty, let data = try? JSONEncoder().encode(metrics) else { return }
        WCSession.default.transferUserInfo([Key.metrics: data])
    }

    func sendAlert(_ message: String) {
        guard isPaired else { return }
        WCSession.default.transferUserInfo([Key.alert: message])
    }

    /// Set by the Watch app to show alerts from the iPhone (e.g. Screen Time access lost).
    var onAlert: (@Sendable (String) -> Void)?

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated, !session.receivedApplicationContext.isEmpty {
            receive(context: session.receivedApplicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        receive(context: context)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo[Key.metrics] as? Data, let metrics = try? JSONDecoder().decode([Metric].self, from: data) {
            Task { @MainActor in await AppModel.shared.record(metrics) }
        }
        if let alert = userInfo[Key.alert] as? String {
            onAlert?(alert)
        }
    }

    private func receive(context: [String: Any]) {
        let remoteSession = (context[Key.session] as? Data).flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
        let goals = (context[Key.goals] as? Data).flatMap { try? JSONDecoder().decode([Goal].self, from: $0) } ?? []
        let recap = context[Key.recapMinutes] as? Int
        let challenge = (context[Key.challenge] as? Data).flatMap { try? JSONDecoder().decode(Challenge.self, from: $0) }
        Task { @MainActor in
            await AppModel.shared.applyRemote(session: remoteSession, goals: goals, recapMinutes: recap, challenge: challenge)
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif
}
