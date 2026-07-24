import Foundation
import Observation

/// Side effects injected by AppDelegate so the flow logic stays unit-testable.
struct SetupActions {
    /// Runs ConfigValidator against a scratch AuthSessionStore.
    var validate: (FirebaseConfig, AuthSessionStore) async -> Result<String, ConfigValidationError>
    /// Adopts the validated session, saves the config, and live-swaps the
    /// sync service (teardown of the old backend included).
    var commit: (SyncConfig, StoredAuthSession) async throws -> Void
    /// Re-reads the local User's invite code after commit, because
    /// startSyncing can regenerate it (e.g. on first registration).
    var fetchOwnInviteCode: () -> String?
    /// Re-reads the stored SyncConfig after an automatic commit, because that
    /// path updates AppDelegate's stored config (not the model) — the model
    /// needs it to build the success screen's share link.
    var fetchCurrentConfig: () -> SyncConfig?
    /// Runs the browser OAuth flow and links (or recovers) the identity.
    /// Returns the linked Google email. Throws GoogleSignInError.cancelled
    /// for quiet abandons; other errors surface to the user.
    var signInWithGoogle: () async throws -> String?
    /// Closes the setup window.
    var dismiss: () -> Void
    /// Builds a fresh AutoHostSetup wired to real services (AppDelegate).
    var makeAutoHostSetup: () -> AutoHostSetup
}

/// Drives the setup window: welcome → host wizard / join / settings.
@MainActor
@Observable
final class SetupModel {
    enum Route: Equatable { case welcome, host, join, settings }
    enum Phase: Equatable {
        case idle, validating, failure(String), success
        /// Connected to VibeCount cloud but Google link is still required.
        case needsGoogleSignIn
    }
    enum HostMode: Equatable { case automatic, manual }

    var route: Route
    var phase: Phase = .idle
    var hostMode: HostMode = .automatic
    private(set) var autoSetup: AutoHostSetup?
    var projectID = ""
    var apiKey = ""
    var joinText = ""
    var googleClientIDField = ""
    var googleClientSecretField = ""
    private(set) var linkedEmail: String?
    private(set) var isSigningInWithGoogle = false
    var signInError: String?

    private(set) var currentConfig: SyncConfig?
    private(set) var ownInviteCode: String?
    let actions: SetupActions

    init(route: Route, currentConfig: SyncConfig?, ownInviteCode: String?,
         linkedEmail: String? = nil, actions: SetupActions) {
        // Older cloud installs may lack the shared OAuth pair on disk.
        self.route = route
        self.currentConfig = currentConfig.map(DefaultSyncProject.enriched)
        self.ownInviteCode = ownInviteCode
        self.linkedEmail = linkedEmail
        self.actions = actions
        if DefaultSyncProject.matches(self.currentConfig), linkedEmail == nil {
            self.phase = .needsGoogleSignIn
        }
    }

    /// Whether committing right now would abandon an existing identity.
    /// Commit always replaces the current identity — even for an identical
    /// config — so the UI must confirm whenever a config is already stored.
    var isSwitchingBackends: Bool { currentConfig != nil }

    /// Whether tapping submit must show a confirmation first. Switching
    /// backends always confirms (identity abandonment); a first-time join
    /// confirms too, so a `vibecount://` deep link prefilled by a webpage can
    /// never point the app at an unexpected backend with a single click.
    var confirmBeforeSubmit: Bool { isSwitchingBackends || route == .join }

    /// Project id the pasted join text would connect to, or nil while it
    /// doesn't parse. Surfaced in the join confirmation so the user sees
    /// exactly which backend their name and usage totals would be uploaded to.
    var pendingJoinProjectID: String? {
        if case .success(let link) = JoinLink.parse(joinText) { return link.projectID }
        return nil
    }

    /// The link any group member can send to a prospective friend.
    var shareLink: String? {
        guard let currentConfig else { return nil }
        var link = JoinLink(projectID: currentConfig.projectID,
                            apiKey: currentConfig.apiKey,
                            hostInviteCode: ownInviteCode)
        link.googleClientID = currentConfig.googleClientID
        link.googleClientSecret = currentConfig.googleClientSecret
        return link.url.absoluteString
    }

    /// True when the current stored config is the shared cloud.
    var isOnDefaultCloud: Bool { DefaultSyncProject.matches(currentConfig) }

    /// VibeCount cloud requires a linked Google account; self-host does not.
    var googleSignInRequired: Bool {
        isOnDefaultCloud && linkedEmail == nil
    }

    /// Show the sign-in button only when the group has a client pair and this
    /// install isn't linked yet. Cloud always has the shared OAuth pair.
    var googleSignInAvailable: Bool {
        guard linkedEmail == nil else { return false }
        if isOnDefaultCloud { return true }
        return currentConfig?.googleClientID != nil
            && currentConfig?.googleClientSecret != nil
    }

    func prefill(joinLink: JoinLink) {
        route = .join
        joinText = joinLink.url.absoluteString
        phase = .idle
    }

    /// Connects to the shared VibeCount Firebase project, then requires Google
    /// sign-in so the identity is durable (reinstall / new Mac recovery).
    func submitDefaultCloud() async {
        await validateAndCommit(DefaultSyncProject.syncConfig)
        guard phase == .success || phase == .needsGoogleSignIn else { return }
        await signInWithGoogle()
        if linkedEmail == nil {
            phase = .needsGoogleSignIn
            if signInError == nil {
                signInError = "Google sign-in is required for VibeCount cloud."
            }
        }
    }

    func submitHost() async {
        let project = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !key.isEmpty else {
            phase = .failure("Enter both the Project ID and the Web API key.")
            return
        }
        let clientID = googleClientIDField.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = googleClientSecretField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.isEmpty == clientSecret.isEmpty else {
            phase = .failure("Enter both the OAuth Client ID and secret, or leave both empty.")
            return
        }
        var config = SyncConfig(projectID: project, apiKey: key, hostInviteCode: nil)
        if !clientID.isEmpty {
            config.googleClientID = clientID
            config.googleClientSecret = clientSecret
        }
        await validateAndCommit(config)
    }

    /// Runs the automatic CLI-driven host setup. On completion, refreshes the
    /// stored config + invite code so the Done screen shows the share link —
    /// the same post-success refresh the manual path does.
    func startAutoHost() async {
        let setup = autoSetup ?? actions.makeAutoHostSetup()
        autoSetup = setup
        await setup.run()
        if setup.finished {
            currentConfig = actions.fetchCurrentConfig() ?? currentConfig
            ownInviteCode = actions.fetchOwnInviteCode() ?? ownInviteCode
            phase = .success
        }
    }

    func submitJoin() async {
        switch JoinLink.parse(joinText) {
        case .failure(let error):
            phase = .failure(error.localizedDescription)
        case .success(let link):
            var config = SyncConfig(
                projectID: link.projectID, apiKey: link.apiKey,
                hostInviteCode: link.hostInviteCode)
            config.googleClientID = link.googleClientID
            config.googleClientSecret = link.googleClientSecret
            await validateAndCommit(config)
            // Joining the shared cloud also requires Google (same policy as
            // the welcome "Use VibeCount cloud" path).
            if phase == .success || phase == .needsGoogleSignIn,
               DefaultSyncProject.matches(currentConfig) {
                await signInWithGoogle()
                if linkedEmail == nil {
                    phase = .needsGoogleSignIn
                    if signInError == nil {
                        signInError = "Google sign-in is required for VibeCount cloud."
                    }
                }
            }
        }
    }

    func signInWithGoogle() async {
        guard !isSigningInWithGoogle else { return }
        isSigningInWithGoogle = true
        signInError = nil
        defer { isSigningInWithGoogle = false }
        do {
            linkedEmail = try await actions.signInWithGoogle() ?? "Google account"
            if linkedEmail != nil, phase == .needsGoogleSignIn {
                phase = .success
            }
        } catch GoogleSignInError.cancelled {
            // Self-host: quiet cancel. Cloud: surface that sign-in is mandatory.
            if googleSignInRequired {
                signInError = "Google sign-in is required for VibeCount cloud."
                phase = .needsGoogleSignIn
            }
        } catch {
            signInError = error.localizedDescription
            if googleSignInRequired {
                phase = .needsGoogleSignIn
            }
        }
    }

    private func validateAndCommit(_ config: SyncConfig) async {
        let config = DefaultSyncProject.enriched(config)
        phase = .validating
        // Scratch store: validation is the real first sign-in, but the session
        // only becomes THE identity if everything succeeds — a failed attempt
        // never disturbs the existing identity or group.
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let scratchStore = AuthSessionStore(directory: scratchDirectory)

        switch await actions.validate(FirebaseConfig(config), scratchStore) {
        case .failure(let error):
            phase = .failure(error.localizedDescription)
        case .success:
            guard let session = scratchStore.load() else {
                phase = .failure("Validation succeeded but no session was stored — please try again.")
                return
            }
            do {
                try await actions.commit(config, session)
                currentConfig = config
                ownInviteCode = actions.fetchOwnInviteCode() ?? ownInviteCode
                // Cloud without a linked Google account is only half-done.
                if DefaultSyncProject.matches(config), linkedEmail == nil {
                    phase = .needsGoogleSignIn
                } else {
                    phase = .success
                }
            } catch {
                phase = .failure(error.localizedDescription)
            }
        }
    }
}
