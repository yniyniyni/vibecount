import Foundation

/// Failure from a firebase CLI operation. `step` names the operation so the UI
/// can point the user at the right place.
enum FirebaseCLIError: Error, Equatable {
    case notInstalled
    case commandFailed(step: String, message: String)
    case malformedOutput(String)
}

/// Thin, typed wrapper over the `firebase` CLI. Holds the resolved binary path
/// and the FIREBASE_TOKEN to inject; all process work goes through `runner`.
struct FirebaseCLI: Sendable {
    let binaryPath: String
    let token: String
    let runner: CommandRunning

    init(binaryPath: String, token: String, runner: CommandRunning = ProcessRunner()) {
        self.binaryPath = binaryPath
        self.token = token
        self.runner = runner
    }

    /// Resolves the firebase binary: each PATH entry, then well-known install
    /// dirs (Homebrew, /usr/local/bin, the standalone-installer ~/.local/bin).
    static func locate(
        pathVariable: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        extraDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin",
                                      "\(NSHomeDirectory())/.local/bin"],
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let dirs = pathVariable.split(separator: ":").map(String.init) + extraDirectories
        for dir in dirs {
            let candidate = "\(dir)/firebase"
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    /// Runs the CLI with FIREBASE_TOKEN injected; throws commandFailed on a
    /// non-zero exit (stderr as the message, stdout as fallback).
    func execute(step: String, _ arguments: [String]) async throws -> String {
        let result = try await runner.run(
            executable: binaryPath,
            arguments: arguments,
            environment: ["FIREBASE_TOKEN": token])
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FirebaseCLIError.commandFailed(
                step: step,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    func version() async throws -> String {
        try await execute(step: "version", ["--version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One project as reported by `firebase projects:list --json`.
struct FirebaseProjectSummary: Equatable, Sendable {
    let projectID: String
    let displayName: String
}

/// The operations AutoHostSetup drives. A protocol so the orchestrator can be
/// tested against a mock without a real CLI.
protocol FirebaseCLIRunning: Sendable {
    func version() async throws -> String
    func createProject(projectID: String, displayName: String) async throws
    func listProjects() async throws -> [FirebaseProjectSummary]
    func createFirestore(projectID: String, location: String) async throws
    func deployRules(projectID: String, rulesPath: String) async throws
    func createWebApp(projectID: String, displayName: String) async throws -> String
    func sdkConfig(projectID: String, appID: String) async throws -> FirebaseConfig
}

extension FirebaseCLI: FirebaseCLIRunning {
    /// Runs a command, swallowing "already exists" so a resumed run is a no-op.
    private func executeIdempotent(step: String, _ arguments: [String]) async throws {
        do {
            _ = try await execute(step: step, arguments)
        } catch FirebaseCLIError.commandFailed(_, let message)
            where message.lowercased().contains("already exists")
                || message.lowercased().contains("already a project") {
            return
        }
    }

    func createProject(projectID: String, displayName: String) async throws {
        try await executeIdempotent(
            step: "createProject",
            ["projects:create", projectID, "--display-name", displayName, "--json"])
    }

    func listProjects() async throws -> [FirebaseProjectSummary] {
        let stdout = try await execute(step: "listProjects", ["projects:list", "--json"])
        struct Payload: Decodable { let result: [Row] }
        struct Row: Decodable { let projectId: String; let displayName: String? }
        guard let rows = try? JSONDecoder().decode(Payload.self, from: Data(stdout.utf8)).result else {
            throw FirebaseCLIError.malformedOutput(stdout)
        }
        return rows.map { FirebaseProjectSummary(projectID: $0.projectId,
                                                 displayName: $0.displayName ?? $0.projectId) }
    }

    func createFirestore(projectID: String, location: String) async throws {
        try await executeIdempotent(
            step: "createFirestore",
            ["firestore:databases:create", "(default)",
             "--project", projectID, "--location", location])
    }

    func deployRules(projectID: String, rulesPath: String) async throws {
        _ = try await execute(
            step: "deployRules",
            ["deploy", "--only", "firestore:rules", "--project", projectID,
             "--config", rulesPath])
    }

    func createWebApp(projectID: String, displayName: String) async throws -> String {
        do {
            let stdout = try await execute(
                step: "createWebApp",
                ["apps:create", "WEB", displayName, "--project", projectID, "--json"])
            struct Payload: Decodable { let result: Row }
            struct Row: Decodable { let appId: String }
            guard let appID = try? JSONDecoder().decode(Payload.self, from: Data(stdout.utf8)).result.appId else {
                throw FirebaseCLIError.malformedOutput(stdout)
            }
            return appID
        }
    }

    func sdkConfig(projectID: String, appID: String) async throws -> FirebaseConfig {
        let stdout = try await execute(
            step: "sdkConfig",
            ["apps:sdkconfig", "WEB", appID, "--project", projectID, "--json"])
        struct Payload: Decodable { let result: Row }
        struct Row: Decodable { let sdkConfig: Inner }
        struct Inner: Decodable { let projectId: String; let apiKey: String }
        guard let inner = try? JSONDecoder().decode(Payload.self, from: Data(stdout.utf8)).result.sdkConfig else {
            throw FirebaseCLIError.malformedOutput(stdout)
        }
        return FirebaseConfig(apiKey: inner.apiKey, projectID: inner.projectId)
    }
}
