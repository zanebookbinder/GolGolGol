import Foundation
import GoalKit

/// Files and settings shared through the App Group. The same identifier is used on iOS (app +
/// extensions) and watchOS (app + widgets); each device has its own container.
enum AppGroup {
    static let id = "group.com.zanebookbinder.goaltracker"
    static let defaults = UserDefaults(suiteName: id)!

    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var storeURL: URL { container.appending(path: "GoalTracker/store.json") }
    static var inbox: MetricInbox { MetricInbox(url: container.appending(path: "GoalTracker/inbox.json")) }

    #if os(iOS)
    /// On iOS the App Group doubles as the Keychain access group, so the monitor extension can upload.
    static let keychain = KeychainSessionStore(accessGroup: id)
    #else
    static let keychain = KeychainSessionStore()
    #endif
}
