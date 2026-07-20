import Foundation
import SwiftData
import os

/// Production fallback when no Firebase configuration is bundled. Tracks only
/// the local user's usage in SwiftData — it never fabricates leaderboard
/// entries and cannot add friends.
@MainActor
public final class LocalOnlySyncService: SyncService {
    public let status = SyncStatus(mode: .localOnly)

    private let context: ModelContext
    private let logger = Logger(subsystem: "com.vibecount.app", category: "sync")

    public init(context: ModelContext) {
        self.context = context
    }

    public func startSyncing() async {
        // Nothing to sync; just drop leaderboard rows that cannot be
        // maintained without sync (old friends, mock data, stale identities).
        do {
            var keep = Set<String>()
            if let userId = try localUser()?.userId {
                keep.insert(userId)
            }
            try FriendReconciler(context: context).removeAll(except: keep)
        } catch {
            logger.error("Local-only reconciliation failed: \(error, privacy: .public)")
            status.lastError = "Couldn't tidy the local leaderboard."
        }
    }

    public func stopSyncing() {}

    public func pushLocalUsage(dailyTokens: Int, monthlyTokens: Int) async throws {
        let user = try ensureLocalUser()
        try FriendReconciler(context: context).upsert(
            id: user.userId,
            displayName: user.displayName,
            dailyTokens: dailyTokens,
            monthlyTokens: monthlyTokens
        )
    }

    public func addFriend(inviteCode: String) async throws {
        throw SyncError.notConfigured
    }

    public func removeFriend(friendId: String) async throws {
        try FriendReconciler(context: context).remove(id: friendId)
    }

    private func localUser() throws -> User? {
        var descriptor = FetchDescriptor<User>()
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func ensureLocalUser() throws -> User {
        if let user = try localUser() {
            return user
        }
        // A purely local identity: it is never uploaded anywhere, and there is
        // no invite code because there is no server to register one with.
        let user = User(
            userId: "local-\(UUID().uuidString.lowercased())",
            displayName: User.sanitizedDisplayName(),
            inviteCode: ""
        )
        context.insert(user)
        try context.save()
        return user
    }
}
