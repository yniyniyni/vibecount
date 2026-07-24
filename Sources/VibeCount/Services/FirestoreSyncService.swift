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
    /// Tags the currently-registered `startTask`, so `startSyncing()` can tell
    /// after an `await` whether it's still the one that registered it — `Task`
    /// is a struct, not identity-comparable, so a UUID stands in for `===`.
    private var startTaskID: UUID?

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
        let taskID = UUID()
        let task = Task { await self.performStart() }
        startTask = task
        startTaskID = taskID
        await task.value
        // A newer start may have already replaced this entry (e.g. this call
        // was itself the stale caller of a cancelled task) — only clear our
        // own slot, never a task registered after us.
        if startTaskID == taskID {
            startTask = nil
            startTaskID = nil
        }
    }

    private func performStart() async {
        do {
            let uid = try await backend.signIn()
            // A stopSyncing() (backend switch) that raced this start wins:
            // never revive a stopped service under a torn-down backend. Checked
            // repeatedly — not just once before `started = true` — because
            // adoptIdentity, registerInviteCode, and ensureRemoteUserDoc all do
            // real damage (identity rewrite, remote writes) under the OLD
            // backend if allowed to run after a cancellation. `guard` (not
            // `try Task.checkCancellation()`) so a cancellation noticed here
            // returns quietly rather than routing through the `catch` below.
            guard !Task.isCancelled else { return }
            let user = try adoptIdentity(uid: uid)
            guard !Task.isCancelled else { return }
            try await registerInviteCode(for: user)
            guard !Task.isCancelled else { return }
            try await ensureRemoteUserDoc(for: user)
            guard !Task.isCancelled else { return }
            started = true
            ownUid = uid
            status.lastError = nil
            logger.info("Sync started")
            await refreshLeaderboard()
        } catch {
            // The guards above only run between awaits — a cancellation that
            // lands while parked inside one is thrown out of it instead
            // (URLSession reports it as URLError.cancelled, not
            // CancellationError). A user asking to stop isn't a sync failure,
            // so it must not paint the dashboard's warning banner.
            if Task.isCancelled { return }
            logger.error("Sync start failed: \(error, privacy: .public)")
            status.lastError = "Sync isn't available: \(error.localizedDescription)"
        }
    }

    public func stopSyncing() {
        startTask?.cancel()
        // Clear the slot too — otherwise the next startSyncing() sees a
        // non-nil (but cancelled-and-dead) startTask, awaits it, and returns
        // without ever starting anything.
        startTask = nil
        startTaskID = nil
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
            "latestDailyCost": .double(0),
            "latestMonthlyCost": .double(0),
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
                        monthlyTokens: document.fields["latestMonthlyTokens"]?.integerValue ?? 0,
                        dailyCost: document.fields["latestDailyCost"]?.doubleValue,
                        monthlyCost: document.fields["latestMonthlyCost"]?.doubleValue)
                } else {
                    // The remote record was deleted; drop the local row.
                    try reconciler.remove(id: id)
                }
            }
            try reconciler.removeAll(except: desired)
        } catch {
            logger.error("Leaderboard refresh failed: \(error, privacy: .public)")
            // Don't clobber a more specific error already surfaced this cycle
            // (e.g. the push that triggered this refresh) — a knock-on
            // failure here is usually the same underlying network problem.
            if status.lastError == nil {
                status.lastError = "Couldn't refresh the leaderboard."
            }
        }
    }

    // MARK: - SyncService

    public func pushLocalUsage(dailyTokens: Int, monthlyTokens: Int, dailyCost: Double = 0, monthlyCost: Double = 0) async throws {
        guard started, let uid = ownUid else {
            // Kick a (re)start for the next poll, but never block this one on
            // it — a hung start must not wedge the polling pipeline.
            Task { await self.startSyncing() }
            throw SyncError.notSignedIn
        }
        let user = try requireLocalUser()
        let displayName = User.sanitizedDisplayName(user.displayName)

        // Local row first so the UI reflects this poll even if the network
        // write below fails.
        try reconciler.upsert(id: uid, displayName: displayName,
                              dailyTokens: dailyTokens, monthlyTokens: monthlyTokens,
                              dailyCost: max(0, dailyCost), monthlyCost: max(0, monthlyCost))

        // The remote write is non-fatal: surface failures through status and
        // let the next poll retry. No offline queue by design.
        do {
            try await backend.patchDocument(path: "users/\(uid)", fields: [
                "displayName": .string(displayName),
                "latestDailyTokens": .integer(max(0, dailyTokens)),
                "latestMonthlyTokens": .integer(max(0, monthlyTokens)),
                "latestDailyCost": .double(max(0, dailyCost)),
                "latestMonthlyCost": .double(max(0, monthlyCost)),
                "lastUpdated": .timestamp(Date()),
            ])
            status.lastError = nil
        } catch {
            logger.error("Usage push failed: \(error, privacy: .public)")
            status.lastError = "Sync failed: \(error.localizedDescription)"
        }

        // Polling model: every push also refreshes the leaderboard.
        await refreshLeaderboard()
    }

    public func addFriend(inviteCode rawCode: String) async throws {
        await startSyncing()
        guard started, let uid = ownUid else {
            throw SyncError.notSignedIn
        }
        guard let code = InviteCode.normalize(rawCode) else {
            throw SyncError.invalidInviteCodeFormat
        }

        guard let codeDoc = try await backend.getDocument(path: "inviteCodes/\(code)"),
              let friendUid = codeDoc.fields["uid"]?.stringValue else {
            throw SyncError.inviteCodeNotFound
        }
        guard friendUid != uid else {
            throw SyncError.ownInviteCode
        }

        // Relationships are create-only in the rules; re-adding an existing
        // friend must not attempt an (always denied) update.
        let relationshipPath = "users/\(uid)/friends/\(friendUid)"
        var createdNow = false
        do {
            try await backend.createDocument(
                parent: "users/\(uid)/friends", documentID: friendUid,
                fields: ["inviteCode": .string(code), "addedAt": .timestamp(Date())])
            createdNow = true
        } catch FirestoreClientError.alreadyExists {
            // Already friends — fine.
        }

        // The relationship is what authorizes reading the friend's doc, so
        // resolve it only now. A missing doc means the code is stale: roll the
        // relationship back and surface a visible error — never a permanent
        // placeholder row.
        let friendDoc: FirestoreDocument?
        do {
            friendDoc = try await backend.getDocument(path: "users/\(friendUid)")
        } catch {
            if createdNow { try? await backend.deleteDocument(path: relationshipPath) }
            throw error
        }
        guard let friendDoc else {
            if createdNow { try? await backend.deleteDocument(path: relationshipPath) }
            throw SyncError.friendUserMissing
        }

        try reconciler.upsert(
            id: friendUid,
            displayName: friendDoc.fields["displayName"]?.stringValue ?? "Unknown",
            dailyTokens: friendDoc.fields["latestDailyTokens"]?.integerValue ?? 0,
            monthlyTokens: friendDoc.fields["latestMonthlyTokens"]?.integerValue ?? 0,
            dailyCost: friendDoc.fields["latestDailyCost"]?.doubleValue,
            monthlyCost: friendDoc.fields["latestMonthlyCost"]?.doubleValue)
    }

    public func removeFriend(friendId: String) async throws {
        guard started, let uid = ownUid else {
            throw SyncError.notSignedIn
        }
        guard friendId != uid else { return } // the UI never offers this

        try await backend.deleteDocument(path: "users/\(uid)/friends/\(friendId)")
        try reconciler.remove(id: friendId)
    }
}
