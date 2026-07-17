// Sources/VibeCount/Services/FirestoreSyncService.swift
import Foundation
import SwiftData
import os

/// The Firestore operations the sync service needs — implemented for real by
/// `FirestoreClient`, and by a mock in tests. Paths are relative to the
/// documents root ("users/abc").
protocol FirestoreBackend: Actor {
    func signIn() async throws -> String
    func getDocument(path: String) async throws -> FirestoreDocument?
    func patchDocument(path: String, fields: [String: FirestoreValue]) async throws
    func createDocument(parent: String, documentID: String, fields: [String: FirestoreValue]) async throws
    func deleteDocument(path: String) async throws
    func listDocuments(path: String) async throws -> [FirestoreDocument]
    func batchGet(paths: [String]) async throws -> [String: FirestoreDocument?]
}

extension FirestoreClient: FirestoreBackend {}

/// Cross-device sync over the Firestore REST API (see
/// docs/superpowers/specs/2026-07-16-firestore-rest-sync-design.md).
///
/// Remote layout (mirrored by firestore.rules — the two are designed together):
///
///     /users/{uid}                      usage doc; owner-write, friend-read
///     /users/{uid}/friends/{friendUid}  explicit follow, created by presenting
///                                       a valid invite code
///     /inviteCodes/{code}               point-lookup registry, create-only
///
/// Freshness is by polling: every `pushLocalUsage` (each usage poll, popover
/// open, and ⌘R) re-fetches the friends list and all usage docs. No listeners,
/// no offline queue — a failed push surfaces in `status` and the next poll
/// retries.
@MainActor
public final class FirestoreSyncService: SyncService {
    public let status = SyncStatus(mode: .firebase)

    private let backend: any FirestoreBackend
    private let container: ModelContainer
    private let logger = Logger(subsystem: "com.vibecount.app", category: "sync")
    private var started = false
    private var ownUid: String?
    private var startTask: Task<Void, Never>?

    init(container: ModelContainer, backend: any FirestoreBackend) {
        self.container = container
        self.backend = backend
    }

    private var reconciler: FriendReconciler {
        FriendReconciler(context: container.mainContext)
    }

    // MARK: - Lifecycle

    public func startSyncing() async {
        if started { return }
        if let inFlight = startTask {
            await inFlight.value
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
        startTask = nil
    }

    private func performStart() async {
        do {
            let uid = try await backend.signIn()
            let user = try adoptIdentity(uid: uid)
            try await registerInviteCode(for: user)
            try await ensureRemoteUserDoc(for: user)
            started = true
            ownUid = uid
            status.lastError = nil
            logger.info("Sync started")
            await refreshLeaderboard()
        } catch {
            logger.error("Sync start failed: \(error, privacy: .public)")
            status.lastError = "Sync isn't available: \(error.localizedDescription)"
        }
    }

    public func stopSyncing() {
        started = false
        ownUid = nil
    }

    // MARK: - Identity

    /// Makes the authenticated uid the canonical local identity, migrating a
    /// legacy row in place, and guarantees the local user row is saved before
    /// anything is uploaded under that identity.
    private func adoptIdentity(uid: String) throws -> User {
        let context = container.mainContext
        var descriptor = FetchDescriptor<User>()
        descriptor.fetchLimit = 1
        if let user = try context.fetch(descriptor).first {
            var needsSave = false
            if user.userId != uid {
                logger.notice("Migrating legacy local identity to Firebase uid")
                user.userId = uid
                needsSave = true
            }
            if InviteCode.normalize(user.inviteCode) == nil {
                // Legacy 8-char (or empty local-only) codes are too guessable
                // to serve as an authorization token — mint a fresh one.
                user.inviteCode = InviteCode.generate()
                needsSave = true
            }
            if needsSave {
                try context.save()
            }
            return user
        }
        let user = User(userId: uid, displayName: User.sanitizedDisplayName(), inviteCode: InviteCode.generate())
        context.insert(user)
        try context.save()
        return user
    }

    /// Ensures /inviteCodes/{code} → own uid exists, regenerating on collision.
    /// Codes are create-only in the rules, so losing a race just means retrying
    /// with a fresh code.
    private func registerInviteCode(for user: User) async throws {
        let context = container.mainContext
        for _ in 0..<3 {
            let code = user.inviteCode
            if let existing = try await backend.getDocument(path: "inviteCodes/\(code)") {
                if existing.fields["uid"]?.stringValue == user.userId {
                    return // already registered by an earlier run
                }
                // Astronomically unlikely 80-bit collision — fall through and
                // mint a new code.
            } else {
                do {
                    try await backend.createDocument(
                        parent: "inviteCodes", documentID: code,
                        fields: ["uid": .string(user.userId), "createdAt": .timestamp(Date())])
                    return
                } catch FirestoreClientError.alreadyExists {
                    // Lost a create race — regenerate and retry.
                    logger.warning("Invite code registration lost a race, regenerating")
                }
            }
            user.inviteCode = InviteCode.generate()
            try context.save()
        }
        throw SyncError.inviteCodeRegistrationFailed
    }

    /// Creates the remote usage doc on first run so a friend who adds this
    /// user's code immediately resolves a real document.
    private func ensureRemoteUserDoc(for user: User) async throws {
        guard try await backend.getDocument(path: "users/\(user.userId)") == nil else { return }
        try await backend.patchDocument(path: "users/\(user.userId)", fields: [
            "displayName": .string(User.sanitizedDisplayName(user.displayName)),
            "latestDailyTokens": .integer(0),
            "latestMonthlyTokens": .integer(0),
            "lastUpdated": .timestamp(Date()),
        ])
    }

    private func requireLocalUser() throws -> User {
        var descriptor = FetchDescriptor<User>()
        descriptor.fetchLimit = 1
        guard let user = try container.mainContext.fetch(descriptor).first else {
            throw SyncError.notSignedIn
        }
        return user
    }

    // MARK: - Leaderboard

    /// Brings local rows in line with remote state: own doc + every friend's
    /// doc in one batchGet; missing docs drop their rows; rows for anyone no
    /// longer in {self} ∪ friends are deleted. Idempotent.
    private func refreshLeaderboard() async {
        guard started, let uid = ownUid else { return }
        do {
            let friendDocs = try await backend.listDocuments(path: "users/\(uid)/friends")
            let desired = Set(friendDocs.map(\.documentID)).union([uid])
            let paths = desired.sorted().map { "users/\($0)" }
            let results = try await backend.batchGet(paths: paths)
            for (path, document) in results {
                let id = String(path.split(separator: "/").last ?? "")
                guard !id.isEmpty else { continue }
                if let document {
                    try reconciler.upsert(
                        id: id,
                        displayName: document.fields["displayName"]?.stringValue ?? "Unknown",
                        dailyTokens: document.fields["latestDailyTokens"]?.integerValue ?? 0,
                        monthlyTokens: document.fields["latestMonthlyTokens"]?.integerValue ?? 0)
                } else {
                    // The remote record was deleted; drop the local row.
                    try reconciler.remove(id: id)
                }
            }
            try reconciler.removeAll(except: desired)
        } catch {
            logger.error("Leaderboard refresh failed: \(error, privacy: .public)")
            status.lastError = "Couldn't refresh the leaderboard."
        }
    }

    // MARK: - SyncService (completed in the next task)

    public func pushLocalUsage(dailyTokens: Int, monthlyTokens: Int) async throws {
        throw SyncError.notSignedIn // implemented in Task 6
    }

    public func addFriend(inviteCode rawCode: String) async throws {
        throw SyncError.notSignedIn // implemented in Task 6
    }

    public func removeFriend(friendId: String) async throws {
        throw SyncError.notSignedIn // implemented in Task 6
    }
}
