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
    /// The client behind the current FirestoreSyncService, kept so account
    /// linking can reach the same session/token state the sync stack uses.
    var firestoreClient: FirestoreClient?
    let syncConfigStore = SyncConfigStore()
    var setupWindow: NSWindow?
    var pricingWindow: NSWindow?
    var usageMonitor: UsageMonitor = CompositeUsageMonitor([
        ClaudeUsageMonitor(),
        CodexUsageMonitor(),
    ])
    /// Latest per-day / per-model breakdown, surfaced to the Stats tab. Updated
    /// each poll; not persisted.
    let usageStats = UsageStats()
    /// Effective per-model pricing (defaults + user overrides), edited in the
    /// Pricing window and read by the Stats view.
    let rates = Rates()
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
        popover.contentSize = NSSize(width: 300, height: 560)
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

        NotificationCenter.default.addObserver(self, selector: #selector(addFriend), name: NSNotification.Name("AddFriend"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(removeFriend(_:)), name: NSNotification.Name("RemoveFriend"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(manualRefresh), name: NSNotification.Name("RefreshData"), object: nil)

        updateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollUsage()
            }
        }

        // Establish sync (identity) first so the first poll can push under
        // the authenticated identity, then poll immediately.
        Task { @MainActor [weak self] in
            await self?.syncService?.startSyncing()
            self?.pollUsage()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(openSyncSettings),
            name: NSNotification.Name("OpenSyncSettings"), object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(openPricing),
            name: NSNotification.Name("OpenPricing"), object: nil)

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

            let usage: UsageBreakdown
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

            // Surface the full breakdown to the Stats tab.
            usageStats.breakdown = usage

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
            // Pre-per-project builds kept one global session file; move it to
            // this project's name once so the existing identity carries over.
            AuthSessionStore.adoptLegacySession(for: config.projectID)
            let client = FirestoreClient(
                config: config,
                store: AuthSessionStore(projectID: config.projectID))
            firestoreClient = client
            return FirestoreSyncService(container: container, backend: client)
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
            .environment(usageStats)
            .environment(rates)
        popover.contentViewController = NSHostingController(rootView: dashboard)
    }

    /// Adopts a validated identity + config and live-swaps the sync service.
    /// Called by SetupModel only after ConfigValidator succeeded.
    func commitSyncConfig(_ config: SyncConfig, session: StoredAuthSession) async throws {
        guard let container else { throw SyncError.notConfigured }
        // Per-project session file: the old project's session stays on disk,
        // so switching back later resumes that identity instead of minting a
        // duplicate user.
        let authStore = AuthSessionStore(projectID: config.projectID)
        // Save-then-purge: a failed save leaves the old identity + config
        // fully intact. A failed purge (after both saves succeed) leaves only
        // stale local friend rows, which refreshLeaderboard's removeAll-except
        // reconciliation cleans up once the new backend starts syncing.
        try authStore.save(session)
        try syncConfigStore.save(config)
        try BackendSwitcher.prepareForNewBackend(context: container.mainContext)

        syncService?.stopSyncing()
        let client = FirestoreClient(config: FirebaseConfig(config), store: authStore)
        firestoreClient = client
        let service = FirestoreSyncService(container: container, backend: client)
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
        // The dashboard posts OpenSyncSettings *synchronously* from inside the
        // popover button's action, so this runs while we're still nested in the
        // transient popover's own click handling. Building an NSWindow and
        // calling NSApp.activate / makeKeyAndOrderFront from there races the
        // popover's dismissal — AppKit tears down the in-flight UI transaction,
        // the status item disappears, and no window ever shows. Close the
        // popover now and present on the next runloop turn, once the click cycle
        // has fully unwound.
        popover?.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.showSetupWindow(route: self.syncConfigStore.load() == nil ? .welcome : .settings)
        }
    }

    @objc func openPricing() {
        // Same deferred presentation as openSyncSettings: unwind the transient
        // popover's click cycle before building/showing the window.
        popover?.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            self?.showPricingWindow()
        }
    }

    func showPricingWindow() {
        pricingWindow?.close()
        let view = PricingView(rates: rates, dismiss: { [weak self] in
            self?.pricingWindow?.close()
            self?.pricingWindow = nil
        })
        let hostingController = NSHostingController(rootView: view)
        // Pin the size ourselves — see the SIGTRAP note in showSetupWindow.
        hostingController.sizingOptions = .standardBounds
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Model Pricing"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 560))
        window.center()
        pricingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSetupWindow(route: SetupModel.Route) {
        setupWindow?.close()
        let ownInviteCode = try? container?.mainContext
            .fetch(FetchDescriptor<User>()).first?.inviteCode
        let storedConfig = syncConfigStore.load()
        let linkedEmail = storedConfig.flatMap {
            AuthSessionStore(projectID: $0.projectID).load()?.linkedEmail
        }
        let model = SetupModel(
            route: route,
            currentConfig: storedConfig,
            ownInviteCode: ownInviteCode,
            linkedEmail: linkedEmail,
            actions: SetupActions(
                validate: { config, store in
                    // Seed the scratch store with any session previously used
                    // with this project: validation then refreshes that
                    // identity (same uid) instead of signing up a duplicate.
                    // A dead token still falls back to a fresh sign-up inside
                    // FirestoreClient.
                    if let previous = AuthSessionStore(projectID: config.projectID).load() {
                        try? store.save(previous)
                    }
                    return await ConfigValidator().validate(config, authStore: store)
                },
                commit: { [weak self] config, session in
                    try await self?.commitSyncConfig(config, session: session)
                },
                fetchOwnInviteCode: { [weak self] in
                    try? self?.container?.mainContext.fetch(FetchDescriptor<User>()).first?.inviteCode
                },
                signInWithGoogle: { [weak self] in
                    guard let self,
                          let stored = self.syncConfigStore.load() else {
                        throw GoogleSignInError.notAvailable
                    }
                    // Cloud configs always get the shared OAuth pair, even if
                    // an older install only saved projectID + apiKey.
                    let config = DefaultSyncProject.enriched(stored)
                    guard let clientID = config.googleClientID,
                          let clientSecret = config.googleClientSecret,
                          let client = self.firestoreClient else {
                        throw GoogleSignInError.notAvailable
                    }
                    // Persist enriched OAuth fields so the next launch is ready.
                    if config.googleClientID != stored.googleClientID
                        || config.googleClientSecret != stored.googleClientSecret {
                        try? self.syncConfigStore.save(config)
                    }
                    let googleToken = try await GoogleSignInFlow()
                        .signIn(clientID: clientID, clientSecret: clientSecret)
                    let outcome = try await client.linkGoogleAccount(googleIDToken: googleToken)
                    switch outcome {
                    case .linked(let email):
                        return email
                    case .recovered(_, let email):
                        // A previous install's identity came back: restart
                        // sync so adoptIdentity migrates the local row and
                        // the recovered friends list re-syncs.
                        self.syncService?.stopSyncing()
                        await self.syncService?.startSyncing()
                        self.pollUsage()
                        return email
                    }
                },
                dismiss: { [weak self] in
                    self?.setupWindow?.close()
                    self?.setupWindow = nil
                }))
        let hostingController = NSHostingController(rootView: SetupView(model: model))
        // NSHostingController defaults to `.preferredContentSize`, which makes it
        // continuously resize the window to SwiftUI's computed content size. On
        // macOS 26 that animated-resize path (NSHostingView.updateAnimatedWindowSize
        // → windowDidLayout) traps (SIGTRAP) while laying out SetupView, killing
        // the app with no crash log or stderr. Drop `.preferredContentSize` and
        // pin the window size ourselves so SwiftUI never drives the resize.
        hostingController.sizingOptions = .standardBounds
        let window = NSWindow(contentViewController: hostingController)
        window.title = "VibeCount Sync"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 500, height: 600))
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
