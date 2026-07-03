import AppKit
import FirebaseCore
import SwiftUI
import SwiftData

@main
struct VibeCountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var container: ModelContainer?
    var syncService: SyncService?
    var usageMonitor: UsageMonitor = ClaudeUsageMonitor()
    var updateTimer: Timer?
    var popover: NSPopover!
    var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            container = try ModelContainer(for: User.self, Friend.self)
            
            // Clean up mock data and legacy localUser from SwiftData
            let context = container!.mainContext
            if let friends = try? context.fetch(FetchDescriptor<Friend>()) {
                for friend in friends {
                    if ["mock1", "mock2", "localUser"].contains(friend.friendId) {
                        context.delete(friend)
                    }
                }
                try? context.save()
            }
            
        } catch {
            print("Failed to create ModelContainer: \(error)")
        }
        
        // Try configuring Firebase
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           FileManager.default.fileExists(atPath: path) {
            FirebaseApp.configure()
            if let container = container {
                syncService = FirebaseSyncService(container: container)
                syncService?.startSyncing()
            }
        } else {
            print("No GoogleService-Info.plist found. Falling back to MockSyncService.")
            if let container = container {
                Task { @MainActor in
                    syncService = MockSyncService(context: container.mainContext)
                    syncService?.startSyncing()
                }
            }
        }
        
        // Setup Popover
        let dashboard = DashboardView()
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: dashboard.modelContainer(container!))
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "VibeCount")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        // Setup event monitor to close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(event)
            }
        }
        
        // Listen for AddFriend Notification from SwiftUI
        NotificationCenter.default.addObserver(self, selector: #selector(addFriend), name: NSNotification.Name("AddFriend"), object: nil)
        
        // Listen for RefreshData Notification from SwiftUI
        NotificationCenter.default.addObserver(self, selector: #selector(manualRefresh), name: NSNotification.Name("RefreshData"), object: nil)
        
        // Start polling usage
        updateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollUsage()
            }
        }
        pollUsage()
    }
    
    @objc func manualRefresh() {
        pollUsage()
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    func getOrCreateLocalUser() -> User? {
        guard let context = container?.mainContext else { return nil }
        let descriptor = FetchDescriptor<User>()
        if let user = try? context.fetch(descriptor).first {
            return user
        }
        
        let newUserId = UUID().uuidString.prefix(8).lowercased()
        let newUser = User(userId: String(newUserId), displayName: NSFullUserName(), inviteCode: String(newUserId))
        context.insert(newUser)
        try? context.save()
        return newUser
    }
    
    func pollUsage() {
        Task { @MainActor in
            do {
                let usage = try await usageMonitor.fetchUsage()
                let dailyTokens = usage.daily
                let monthlyTokens = usage.monthly
                
                // Format tokens (e.g. 1.5M, 12k, 2B)
                var title = ""
                if dailyTokens >= 1_000_000_000 {
                    title = String(format: " %.1fB", Double(dailyTokens) / 1_000_000_000.0)
                } else if dailyTokens >= 1_000_000 {
                    title = String(format: " %.1fM", Double(dailyTokens) / 1_000_000.0)
                } else if dailyTokens >= 1_000 {
                    title = String(format: " %.1fk", Double(dailyTokens) / 1_000.0)
                } else {
                    title = " \(dailyTokens)"
                }
                title = title.replacingOccurrences(of: ".0", with: "")
                
                // Update menu bar text
                if let button = statusItem?.button {
                    button.title = title
                }
                
                // Get local user
                guard let user = getOrCreateLocalUser() else { return }
                
                // Push to sync service
                try await syncService?.pushLocalUsage(userId: user.userId, displayName: user.displayName, dailyTokens: dailyTokens, monthlyTokens: monthlyTokens)
                
            } catch {
                print("Failed to fetch usage: \(error)")
            }
        }
    }
    
    @objc func addFriend() {
        let alert = NSAlert()
        alert.messageText = "Add Friend"
        alert.informativeText = "Enter your friend's Invite Code (User ID):"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        let inputTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        inputTextField.placeholderString = "e.g. some-user-id"
        alert.accessoryView = inputTextField
        
        // Show window and bring to front
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let friendId = inputTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !friendId.isEmpty {
                Task { @MainActor in
                    guard let context = container?.mainContext else { return }
                    
                    let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.friendId == friendId })
                    if (try? context.fetch(descriptor).first) == nil {
                        let newFriend = Friend(friendId: friendId, displayName: "Loading...", latestDailyTokens: 0, latestMonthlyTokens: 0, lastUpdated: Date())
                        context.insert(newFriend)
                        try? context.save()
                    }
                }
            }
        }
    }
}
