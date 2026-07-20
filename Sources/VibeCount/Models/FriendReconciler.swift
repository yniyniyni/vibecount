import Foundation
import SwiftData

/// Applies remote leaderboard state to the local SwiftData store. All methods
/// persist immediately and propagate persistence errors to the caller — a
/// failed fetch or save is never silently swallowed.
@MainActor
struct FriendReconciler {
    let context: ModelContext

    /// Insert-or-update one leaderboard row and save.
    func upsert(id: String, displayName: String, dailyTokens: Int, monthlyTokens: Int) throws {
        try Friend.upsert(
            friendId: id,
            displayName: displayName,
            dailyTokens: dailyTokens,
            monthlyTokens: monthlyTokens,
            in: context
        )
        try context.save()
    }

    /// Remove the row for `id` if present (no-op when absent) and save.
    func remove(id: String) throws {
        let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.friendId == id })
        let rows = try context.fetch(descriptor)
        guard !rows.isEmpty else { return }
        for row in rows {
            context.delete(row)
        }
        try context.save()
    }

    /// Delete every row whose id is not in `keep` — the reconciliation step
    /// that clears rows for removed friendships, stale legacy identities, and
    /// leftover mock data.
    func removeAll(except keep: Set<String>) throws {
        let rows = try context.fetch(FetchDescriptor<Friend>())
        var changed = false
        for row in rows where !keep.contains(row.friendId) {
            context.delete(row)
            changed = true
        }
        if changed {
            try context.save()
        }
    }
}
