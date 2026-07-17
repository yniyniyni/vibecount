// Sources/VibeCount/Models/Schema.swift
import Foundation
import SwiftData

@Model
public final class User {
    @Attribute(.unique) public var userId: String
    public var displayName: String
    public var inviteCode: String
    
    public init(userId: String, displayName: String, inviteCode: String) {
        self.userId = userId
        self.displayName = displayName
        self.inviteCode = inviteCode
    }
}

extension User {
    /// Display name safe for upload: trimmed, 1–50 characters, never empty.
    /// Mirrors the `displayName` constraints enforced by firestore.rules.
    static func sanitizedDisplayName(_ raw: String = NSFullUserName()) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let clamped = String(trimmed.prefix(50))
        return clamped.isEmpty ? "Anonymous" : clamped
    }
}

@Model
public final class Friend {
    @Attribute(.unique) public var friendId: String
    public var displayName: String
    public var latestDailyTokens: Int
    public var latestMonthlyTokens: Int = 0
    public var lastUpdated: Date
    
    public init(friendId: String, displayName: String, latestDailyTokens: Int, latestMonthlyTokens: Int = 0, lastUpdated: Date) {
        self.friendId = friendId
        self.displayName = displayName
        self.latestDailyTokens = latestDailyTokens
        self.latestMonthlyTokens = latestMonthlyTokens
        self.lastUpdated = lastUpdated
    }
}
