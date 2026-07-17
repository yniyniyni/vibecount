// Sources/VibeCount/Services/SyncService.swift
import Foundation
import Observation

/// How the app is currently persisting leaderboard data.
public enum SyncMode: Sendable, Equatable {
    /// Cross-device sync through Firebase (anonymous auth + Firestore).
    case firebase
    /// No Firebase configuration bundled: only the local user's own usage is
    /// tracked, on this machine, and friends are unavailable.
    case localOnly
}

public enum SyncError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case invalidInviteCodeFormat
    case inviteCodeNotFound
    case ownInviteCode
    case friendUserMissing
    case inviteCodeRegistrationFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Friends require Firebase sync, which isn't set up on this install. See the README for setup."
        case .notSignedIn:
            "Not signed in to sync yet — check your network connection and try again."
        case .invalidInviteCodeFormat:
            "That doesn't look like a valid invite code."
        case .inviteCodeNotFound:
            "No user was found for that invite code."
        case .ownInviteCode:
            "That's your own invite code."
        case .friendUserMissing:
            "That invite code's user no longer exists."
        case .inviteCodeRegistrationFailed:
            "Couldn't register an invite code for this device."
        }
    }
}

/// Small observable surface the dashboard reads to show sync state, so
/// failures land in the UI instead of only in log lines.
@MainActor
@Observable
public final class SyncStatus {
    public let mode: SyncMode
    /// Human-readable description of the most recent failure; nil when healthy.
    public var lastError: String?

    public init(mode: SyncMode, lastError: String? = nil) {
        self.mode = mode
        self.lastError = lastError
    }
}

@MainActor
public protocol SyncService: AnyObject {
    var status: SyncStatus { get }

    /// Establish identity and listeners. Idempotent — safe to call repeatedly,
    /// so a launch without network heals itself on a later poll.
    func startSyncing() async

    /// Tear down all listeners. Idempotent.
    func stopSyncing()

    /// Persist the local user's usage locally and (when syncing) remotely.
    func pushLocalUsage(dailyTokens: Int, monthlyTokens: Int) async throws

    /// Resolve an invite code to a real user and add them as a friend.
    /// Throws a `SyncError` describing exactly why a code couldn't be added.
    func addFriend(inviteCode: String) async throws

    /// Remove a friend relationship and its local leaderboard row.
    func removeFriend(friendId: String) async throws
}
