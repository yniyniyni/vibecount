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
    /// Runs the browser OAuth flow and links (or recovers) the identity.
    /// Returns the linked Google email. Throws GoogleSignInError.cancelled
    /// for quiet abandons; other errors surface to the user.
    var signInWithGoogle: () async throws -> String?
    /// Closes the setup window.
    var dismiss: () -> Void
}

/// Drives the setup window: welcome → host wizard / join / settings.
@MainActor
@Observable
final class SetupModel {
    enum Route: Equatable { case welcome, host, join, settings }
    enum Phase: Equatable { case idle, validating, failure(String), success }

    var route: Route
    var phase: Phase = .idle
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
        self.route = route
        self.currentConfig = currentConfig
        self.ownInviteCode = ownInviteCode
        self.linkedEmail = linkedEmail
        self.actions = actions
    }

    /// Whether committing right now would abandon an existing identity.
    /// Commit always replaces the current identity — even for an identical
    /// config — so the UI must confirm whenever a config is already stored.
    var isSwitchingBackends: Bool { currentConfig != nil }

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

    /// Show the sign-in button only when the group has a client pair and this
    /// install isn't linked yet.
    var googleSignInAvailable: Bool {
        currentConfig?.googleClientID != nil
            && currentConfig?.googleClientSecret != nil
            && linkedEmail == nil
    }

    func prefill(joinLink: JoinLink) {
        route = .join
        joinText = joinLink.url.absoluteString
        phase = .idle
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
        }
    }

    func signInWithGoogle() async {
        guard !isSigningInWithGoogle else { return }
        isSigningInWithGoogle = true
        signInError = nil
        defer { isSigningInWithGoogle = false }
        do {
            linkedEmail = try await actions.signInWithGoogle() ?? "Google account"
        } catch GoogleSignInError.cancelled {
            // Closed tab / denied consent / timeout — quiet by design.
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func validateAndCommit(_ config: SyncConfig) async {
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
                phase = .success
            } catch {
                phase = .failure(error.localizedDescription)
            }
        }
    }
}
