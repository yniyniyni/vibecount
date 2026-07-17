import Foundation
import SwiftData

/// Cleanup when the app moves to a different Firebase project. An anonymous
/// identity is per-project — the uid, refresh token, friend relationships,
/// and invite-code registration all die with the old backend. The local User
/// row survives so the display name (and usage history) carry over.
///
/// The auth session itself is replaced by saving the newly validated session
/// over it (the caller does this), so no explicit clear is needed here.
/// Friends are just a local cache of the old group's roster, so they're
/// purged last, after the new identity + config are already durable.
@MainActor
enum BackendSwitcher {
    static func prepareForNewBackend(context: ModelContext) throws {
        for friend in try context.fetch(FetchDescriptor<Friend>()) {
            context.delete(friend)
        }
        try context.save()
    }
}
