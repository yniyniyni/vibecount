import Foundation
import Observation

/// The ordered steps of automatic self-host setup.
enum AutoSetupStep: Int, CaseIterable, Sendable {
    case checkCLI, signIn, createProject, createFirestore, deployRules, registerApp, enableAuth, commit

    var title: String {
        switch self {
        case .checkCLI: "Check Firebase CLI"
        case .signIn: "Sign in with Google"
        case .createProject: "Create Firebase project"
        case .createFirestore: "Provision Firestore"
        case .deployRules: "Deploy security rules"
        case .registerApp: "Register app & read config"
        case .enableAuth: "Enable Anonymous auth"
        case .commit: "Connect VibeCount"
        }
    }
}

enum StepState: Equatable, Sendable { case pending, running, done, failed(String) }

/// Side effects injected so the orchestrator stays unit-testable.
struct AutoSetupDependencies {
    var locateCLI: () -> String?
    var makeCLI: (_ binaryPath: String, _ refreshToken: String) -> FirebaseCLIRunning
    var signIn: () async throws -> GoogleTokens
    var accessToken: (_ refreshToken: String) async throws -> String
    var enableAnonymous: (_ projectID: String, _ accessToken: String) async throws -> Void
    var rulesPath: () -> String?
    var commit: (_ config: SyncConfig) async -> Result<Void, ConfigValidationError>
    var newProjectID: () -> String
}

/// Runs the automatic self-host setup as a resumable state machine. Each step
/// runs only if not already `.done`, so re-invoking `run()` after a failure
/// retries from the failed step without repeating completed work.
@MainActor
@Observable
final class AutoHostSetup {
    var location = "eur3"
    /// When set, reuse this project instead of creating a new one.
    var existingProjectID: String?
    private(set) var states: [AutoSetupStep: StepState] =
        Dictionary(uniqueKeysWithValues: AutoSetupStep.allCases.map { ($0, .pending) })
    private(set) var installNeeded = false
    private(set) var finished = false

    private let dependencies: AutoSetupDependencies
    // Carried between steps (and across a resume).
    private var refreshToken: String?
    private var projectID: String?
    private var config: FirebaseConfig?

    init(dependencies: AutoSetupDependencies) { self.dependencies = dependencies }

    func run() async {
        installNeeded = false
        do {
            try await step(.checkCLI) {
                guard self.dependencies.locateCLI() != nil else {
                    self.installNeeded = true
                    throw StepError("The firebase CLI isn't installed.")
                }
            }
            try await step(.signIn) {
                self.refreshToken = try await self.dependencies.signIn().refreshToken
            }
            let binary = dependencies.locateCLI()!
            let cli = dependencies.makeCLI(binary, refreshToken!)
            try await step(.createProject) {
                if let existing = self.existingProjectID {
                    self.projectID = existing
                } else {
                    let id = self.dependencies.newProjectID()
                    try await cli.createProject(projectID: id, displayName: "VibeCount")
                    self.projectID = id
                }
            }
            let project = projectID!
            try await step(.createFirestore) {
                try await cli.createFirestore(projectID: project, location: self.location)
            }
            try await step(.deployRules) {
                guard let path = self.dependencies.rulesPath() else {
                    throw StepError("Bundled security rules are missing.")
                }
                try await cli.deployRules(projectID: project, rulesPath: path)
            }
            try await step(.registerApp) {
                let appID = try await cli.createWebApp(projectID: project, displayName: "VibeCount")
                self.config = try await cli.sdkConfig(projectID: project, appID: appID)
            }
            try await step(.enableAuth) {
                let token = try await self.dependencies.accessToken(self.refreshToken!)
                try await self.dependencies.enableAnonymous(project, token)
            }
            try await step(.commit) {
                let firebaseConfig = self.config!
                let syncConfig = SyncConfig(projectID: firebaseConfig.projectID,
                                            apiKey: firebaseConfig.apiKey, hostInviteCode: nil)
                if case .failure(let error) = await self.dependencies.commit(syncConfig) {
                    throw StepError(error.errorDescription ?? "Validation failed.")
                }
            }
            finished = true
        } catch {
            // The failing step already recorded its .failed state in `step`.
        }
    }

    /// Runs `body` only if the step isn't already done, tracking running/done/
    /// failed. Rethrows so `run` halts the chain.
    private func step(_ step: AutoSetupStep, _ body: () async throws -> Void) async throws {
        if states[step] == .done { return }
        states[step] = .running
        do {
            try await body()
            states[step] = .done
        } catch {
            let message = (error as? StepError)?.message
                ?? (error as? FirebaseCLIError).map(Self.describe)
                ?? (error as? AnonymousAuthError).map(Self.describe)
                ?? error.localizedDescription
            states[step] = .failed(message)
            throw error
        }
    }

    private struct StepError: Error { let message: String; init(_ m: String) { message = m } }

    private static func describe(_ error: FirebaseCLIError) -> String {
        switch error {
        case .notInstalled: "The firebase CLI isn't installed."
        case .commandFailed(_, let message): message
        case .malformedOutput: "Unexpected output from the firebase CLI."
        }
    }
    private static func describe(_ error: AnonymousAuthError) -> String {
        switch error {
        case .http(_, let message): message
        case .network(let message): message
        }
    }
}
