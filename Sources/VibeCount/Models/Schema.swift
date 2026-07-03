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

@Model
public final class TokenLog {
    @Attribute(.unique) public var id: UUID
    public var timestamp: Date
    public var tokensBurned: Int
    public var model: String
    
    public init(id: UUID = UUID(), timestamp: Date, tokensBurned: Int, model: String) {
        self.id = id
        self.timestamp = timestamp
        self.tokensBurned = tokensBurned
        self.model = model
    }
}
