import Foundation
import SwiftData

extension Friend {
    /// Inserts or updates the leaderboard row keyed by `friendId`. When the row
    /// already exists it is mutated in place so live SwiftUI `@Query` views update
    /// the row rather than replacing it. Callers own the `save()`, so several
    /// upserts (e.g. a Firestore snapshot batch) can be persisted in one write.
    ///
    /// A thrown error means the store could not be read or written — it is never
    /// treated as "record not found". Only a successful fetch that returns no
    /// row leads to an insert.
    @MainActor
    static func upsert(
        friendId: String,
        displayName: String,
        dailyTokens: Int,
        monthlyTokens: Int,
        dailyCost: Double? = nil,
        monthlyCost: Double? = nil,
        in context: ModelContext
    ) throws {
        var descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.friendId == friendId })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.displayName = displayName
            existing.latestDailyTokens = dailyTokens
            existing.latestMonthlyTokens = monthlyTokens
            existing.latestDailyCost = dailyCost
            existing.latestMonthlyCost = monthlyCost
            existing.lastUpdated = Date()
        } else {
            let friend = Friend(
                friendId: friendId,
                displayName: displayName,
                latestDailyTokens: dailyTokens,
                latestMonthlyTokens: monthlyTokens,
                latestDailyCost: dailyCost,
                latestMonthlyCost: monthlyCost,
                lastUpdated: Date()
            )
            context.insert(friend)
        }
    }
}
