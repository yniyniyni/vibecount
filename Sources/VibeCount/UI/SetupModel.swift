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

    private(set) var currentConfig: SyncConfig?
    private(set) var ownInviteCode: String?
    let actions: SetupActions

    init(route: Route, currentConfig: SyncConfig?, ownInviteCode: String?, actions: SetupActions) {
        self.route = route
        self.currentConfig = currentConfig
        self.ownInviteCode = ownInviteCode
        self.actions = actions
    }

    /// Whether committing right now would abandon an existing identity.
    /// Commit always replaces the current identity — even for an identical
    /// config — so the UI must confirm whenever a config is already stored.
    var isSwitchingBackends: Bool { currentConfig != nil }

    /// The link any group member can send to a prospective friend.
    var shareLink: String? {
        guard let currentConfig else { return nil }
        return JoinLink(projectID: currentConfig.projectID,
                        apiKey: currentConfig.apiKey,
                        hostInviteCode: ownInviteCode).url.absoluteString
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
        await validateAndCommit(SyncConfig(projectID: project, apiKey: key, hostInviteCode: nil))
    }

    func submitJoin() async {
        switch JoinLink.parse(joinText) {
        case .failure(let error):
            phase = .failure(error.localizedDescription)
        case .success(let link):
            await validateAndCommit(SyncConfig(
                projectID: link.projectID, apiKey: link.apiKey,
                hostInviteCode: link.hostInviteCode))
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
