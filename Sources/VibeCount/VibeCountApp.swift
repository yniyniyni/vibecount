import AppKit
import SwiftUI
import SwiftData
import os

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
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var container: ModelContainer?
    var syncService: (any SyncService)?
    let syncConfigStore = SyncConfigStore()
    var setupWindow: NSWindow?
    var usageMonitor: UsageMonitor = ClaudeUsageMonitor()
    var updateTimer: Timer?
    var popover: NSPopover!
    var eventMonitor: Any?
    /// Guards against overlapping polls. Each poll does a full disk scan plus a
    /// Firestore write, so rapid triggers (repeated popover opens, timer + manual
    /// refresh) must not stack up and race the button title / network writes.
    var isPolling = false

    private let logger = Logger(subsystem: "com.vibecount.app", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            container = try ModelContainer(for: User.self, Friend.self)
        } catch {
            logger.fault("Failed to create ModelContainer: \(error, privacy: .public)")
        }

        // A nil container means the on-disk store failed to open or migrate.
        // Nothing downstream can run without it (the popover binds it directly),
        // so fail loudly here instead of force-unwrapping into a crash later.
        guard let container = container else {
            let alert = NSAlert()
            alert.messageText = "VibeCount can't start"
            alert.informativeText = "Failed to open the local data store. Please restart the app, and reinstall if the problem persists."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Sync config: user-entered (Application Support) beats a bundled
        // GoogleService-Info.plist; with neither, run local-only.
        syncService = makeSyncService(container: container)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        rebuildPopoverContent()
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "VibeCount")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Setup event monitor to close popover when clicking outside. The
        // handler is nonisolated, so hop to the main actor before touching UI.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let popover = self.popover, popover.isShown else { return }
                popover.performClose(nil)
            }
        }

        // Listen for dashboard actions posted from SwiftUI
        NotificationCenter.default.addObserver(self, selector: #selector(addFriend), name: NSNotification.Name("AddFriend"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(removeFriend(_:)), name: NSNotification.Name("RemoveFriend"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(manualRefresh), name: NSNotification.Name("RefreshData"), object: nil)

        // Start polling usage
        updateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollUsage()
            }
        }

        // Establish sync (identity + listeners) first so the first poll can
        // push under the authenticated identity, then poll immediately.
        Task { @MainActor [weak self] in
            await self?.syncService?.startSyncing()
            self?.pollUsage()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(openSyncSettings),
            name: NSNotification.Name("OpenSyncSettings"), object: nil)

        // First run with no backend at all: offer setup once. Skipping is
        // remembered; the popover's "Sync Settings…" reopens it anytime.
        if FirebaseConfig.resolve(store: syncConfigStore, bundled: FirebaseConfig.load()) == nil,
           !UserDefaults.standard.bool(forKey: "didOfferSetup") {
            UserDefaults.standard.set(true, forKey: "didOfferSetup")
            showSetupWindow(route: .welcome)
        }
    }

    @objc func manualRefresh() {
        pollUsage()
    }

    /// Titlebar close bypasses the SwiftUI dismiss action; release the
    /// window and its model here so they don't linger until the next open.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === setupWindow else { return }
        setupWindow = nil
        pendingSetupModel = nil
    }

    func popoverWillShow(_ notification: Notification) {
        // Refresh right before the popover appears so it never shows data older
        // than the 600s polling interval, regardless of how it was opened.
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

    func pollUsage() {
        // Skip if a poll is already in flight so overlapping triggers can't stack
        // concurrent disk scans / Firestore writes or race the button title.
        guard !isPolling else { return }
        isPolling = true
        Task { @MainActor in
            defer { isPolling = false }

            let usage: DailyMonthlyUsage
            do {
                usage = try await usageMonitor.fetchUsage()
            } catch is CancellationError {
                return
            } catch {
                // A local disk-scan problem — reported distinctly from any
                // sync failure below so the two can't be confused.
                logger.error("Reading Claude usage logs failed: \(error, privacy: .public)")
                syncService?.status.lastError = "Couldn't read the Claude usage logs."
                return
            }

            // Update menu bar text (leading space separates it from the flame icon)
            if let button = statusItem?.button {
                button.title = " " + usage.daily.formattedTokenCount
            }

            do {
                try await syncService?.pushLocalUsage(dailyTokens: usage.daily, monthlyTokens: usage.monthly)
            } catch {
                logger.error("Pushing usage failed: \(error, privacy: .public)")
                syncService?.status.lastError = "Sync failed: \(error.localizedDescription)"
            }
        }
    }

    @objc func addFriend() {
        let alert = NSAlert()
        alert.messageText = "Add Friend"
        alert.informativeText = "Enter your friend's invite code:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let inputTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        inputTextField.placeholderString = "e.g. ABCD-EFGH-2345-6789"
        alert.accessoryView = inputTextField

        // Show window and bring to front
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let code = inputTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }

        Task { @MainActor in
            do {
                try await syncService?.addFriend(inviteCode: code)
            } catch {
                self.presentError(title: "Couldn't Add Friend", error: error)
            }
        }
    }

    @objc func removeFriend(_ notification: Notification) {
        guard let friendId = notification.userInfo?["friendId"] as? String else { return }
        Task { @MainActor in
            do {
                try await syncService?.removeFriend(friendId: friendId)
            } catch {
                self.presentError(title: "Couldn't Remove Friend", error: error)
            }
        }
    }

    private func presentError(title: String, error: Error) {
        logger.error("\(title, privacy: .public): \(error, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Sync backend management

    private func makeSyncService(container: ModelContainer) -> any SyncService {
        if let config = FirebaseConfig.resolve(store: syncConfigStore, bundled: FirebaseConfig.load()) {
            return FirestoreSyncService(container: container, backend: FirestoreClient(config: config))
        }
        logger.notice("No sync config (stored or bundled) — running local-only.")
        return LocalOnlySyncService(context: container.mainContext)
    }

    /// The popover binds a specific service's status at construction, so a
    /// backend swap rebuilds its content view.
    private func rebuildPopoverContent() {
        guard let container, let syncService else { return }
        let dashboard = DashboardView()
            .modelContainer(container)
            .environment(syncService.status)
        popover.contentViewController = NSHostingController(rootView: dashboard)
    }

    /// Adopts a validated identity + config and live-swaps the sync service.
    /// Called by SetupModel only after ConfigValidator succeeded.
    func commitSyncConfig(_ config: SyncConfig, session: StoredAuthSession) async throws {
        guard let container else { throw SyncError.notConfigured }
        let authStore = AuthSessionStore()
        try BackendSwitcher.prepareForNewBackend(context: container.mainContext, authStore: authStore)
        try authStore.save(session)
        try syncConfigStore.save(config)

        syncService?.stopSyncing()
        let service = FirestoreSyncService(
            container: container,
            backend: FirestoreClient(config: FirebaseConfig(config)))
        syncService = service
        rebuildPopoverContent()
        await service.startSyncing()
        // Auto-friend the host so a joiner's leaderboard is never empty.
        // Best-effort: a failure here still leaves a working backend.
        if let hostCode = config.hostInviteCode {
            try? await service.addFriend(inviteCode: hostCode)
        }
        pollUsage()
    }

    // MARK: - Setup window

    @objc func openSyncSettings() {
        showSetupWindow(route: syncConfigStore.load() == nil ? .welcome : .settings)
    }

    func showSetupWindow(route: SetupModel.Route) {
        setupWindow?.close()
        let ownInviteCode = try? container?.mainContext
            .fetch(FetchDescriptor<User>()).first?.inviteCode
        let model = SetupModel(
            route: route,
            currentConfig: syncConfigStore.load(),
            ownInviteCode: ownInviteCode,
            actions: SetupActions(
                validate: { config, store in
                    await ConfigValidator().validate(config, authStore: store)
                },
                commit: { [weak self] config, session in
                    try await self?.commitSyncConfig(config, session: session)
                },
                dismiss: { [weak self] in
                    self?.setupWindow?.close()
                    self?.setupWindow = nil
                }))
        let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
        window.title = "VibeCount Sync"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pendingSetupModel = model
    }

    /// Kept so the deep-link handler can prefill an already-open window.
    var pendingSetupModel: SetupModel?

    // MARK: - Deep links

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        switch JoinLink.parse(url: url) {
        case .failure(let error):
            presentError(title: "Couldn't Open Join Link", error: error)
        case .success(let link):
            showSetupWindow(route: .join)
            pendingSetupModel?.prefill(joinLink: link)
        }
    }
}
