// Tests/VibeCountTests/MockSyncService.swift
import Foundation
import SwiftData
@testable import VibeCount

/// Test-only SyncService double: records calls and mirrors pushes into the
/// local store the way a real service would. It lives in the test target on
/// purpose — production offline mode is `LocalOnlySyncService`, which never
/// fabricates data.
@MainActor
final class MockSyncService: SyncService {
    let status = SyncStatus(mode: .localOnly)

    private let context: ModelContext
    private(set) var started = false
    private(set) var pushed: [(daily: Int, monthly: Int)] = []
    private(set) var addedInviteCodes: [String] = []
    private(set) var removedFriendIds: [String] = []

    init(context: ModelContext) {
        self.context = context
    }

    func startSyncing() async {
        started = true
    }

    func stopSyncing() {
        started = false
    }

    func pushLocalUsage(dailyTokens: Int, monthlyTokens: Int) async throws {
        pushed.append((dailyTokens, monthlyTokens))
        try Friend.upsert(
            friendId: "test-user",
            displayName: "Test User",
            dailyTokens: dailyTokens,
            monthlyTokens: monthlyTokens,
            in: context
        )
        try context.save()
    }

    func addFriend(inviteCode: String) async throws {
        addedInviteCodes.append(inviteCode)
    }

    func removeFriend(friendId: String) async throws {
        removedFriendIds.append(friendId)
        try FriendReconciler(context: context).remove(id: friendId)
    }
}
