import Foundation
import SwiftData
import FirebaseCore
@preconcurrency import FirebaseFirestore

@MainActor
public protocol SyncService: Sendable {
    func startSyncing()
    func stopSyncing()
    func pushLocalUsage(userId: String, displayName: String, dailyTokens: Int, monthlyTokens: Int) async throws
}

@MainActor
public final class MockSyncService: SyncService {
    private let context: ModelContext
    
    public init(context: ModelContext) {
        self.context = context
    }
    
    public func startSyncing() {
        print("MockSyncService: Started syncing")
        // Create some mock friends
        let f1 = Friend(friendId: "mock1", displayName: "Alice", latestDailyTokens: 45000, latestMonthlyTokens: 1_200_000, lastUpdated: Date())
        let f2 = Friend(friendId: "mock2", displayName: "Bob", latestDailyTokens: 12000, latestMonthlyTokens: 300_000, lastUpdated: Date())
        context.insert(f1)
        context.insert(f2)
        try? context.save()
    }
    
    public func stopSyncing() {
        print("MockSyncService: Stopped syncing")
    }
    
    public func pushLocalUsage(userId: String, displayName: String, dailyTokens: Int, monthlyTokens: Int) async throws {
        print("MockSyncService: Pushed \(dailyTokens) daily, \(monthlyTokens) monthly tokens for \(displayName)")

        Friend.upsert(friendId: userId, displayName: displayName, dailyTokens: dailyTokens, monthlyTokens: monthlyTokens, in: context)
        try? context.save()
    }
}

@MainActor
public final class FirebaseSyncService: SyncService {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private let container: ModelContainer
    
    public init(container: ModelContainer) {
        self.container = container
    }
    
    public func startSyncing() {
        // Listen to the 'users' collection in Firestore
        listener = db.collection("users").addSnapshotListener { [weak self] snapshot, error in
            guard let documents = snapshot?.documents, error == nil else {
                print("Error fetching snapshot: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            Task { @MainActor in
                guard let self = self else { return }
                let context = self.container.mainContext
                
                for document in documents {
                    let data = document.data()
                    let id = document.documentID
                    let displayName = data["displayName"] as? String ?? "Unknown"
                    let dTokens = data["latestDailyTokens"] as? Int ?? 0
                    let mTokens = data["latestMonthlyTokens"] as? Int ?? 0

                    Friend.upsert(friendId: id, displayName: displayName, dailyTokens: dTokens, monthlyTokens: mTokens, in: context)
                }
                try? context.save()
            }
        }
    }
    
    public func stopSyncing() {
        listener?.remove()
        listener = nil
    }
    
    public func pushLocalUsage(userId: String, displayName: String, dailyTokens: Int, monthlyTokens: Int) async throws {
        // Save to local SwiftData context so user appears in UI instantly
        let context = container.mainContext
        Friend.upsert(friendId: userId, displayName: displayName, dailyTokens: dailyTokens, monthlyTokens: monthlyTokens, in: context)
        try? context.save()

        // Push to Firebase
        let data: [String: Any] = [
            "displayName": displayName,
            "latestDailyTokens": dailyTokens,
            "latestMonthlyTokens": monthlyTokens,
            "lastUpdated": FieldValue.serverTimestamp()
        ]
        try await db.collection("users").document(userId).setData(data, merge: true)
    }
}


