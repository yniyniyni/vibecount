// Sources/VibeCount/Models/LeaderboardTab.swift
import Foundation

/// The two leaderboard views. Each tab sorts by the same figure it displays,
/// so the ranking always matches the numbers on screen.
enum LeaderboardTab: Hashable, CaseIterable {
    case today
    case last30Days

    var title: String {
        switch self {
        case .today: "Today"
        case .last30Days: "Last 30 Days"
        }
    }

    /// The figure this tab displays for a row.
    func tokens(for friend: Friend) -> Int {
        switch self {
        case .today: friend.latestDailyTokens
        case .last30Days: friend.latestMonthlyTokens
        }
    }

    /// Rows ordered by this tab's figure, descending. Name breaks ties so the
    /// ordering is deterministic.
    func sorted(_ friends: [Friend]) -> [Friend] {
        friends.sorted { lhs, rhs in
            let left = tokens(for: lhs)
            let right = tokens(for: rhs)
            if left != right { return left > right }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
