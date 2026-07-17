import Foundation
import SwiftData

/// Cleanup when the app moves to a different Firebase project. An anonymous
/// identity is per-project — the uid, refresh token, friend relationships,
/// and invite-code registration all die with the old backend. The local User
/// row survives so the display name (and usage history) carry over.
@MainActor
enum BackendSwitcher {
    static func prepareForNewBackend(context: ModelContext, authStore: AuthSessionStore) throws {
        for friend in try context.fetch(FetchDescriptor<Friend>()) {
            context.delete(friend)
        }
        try context.save()
        authStore.clear()
    }
}
