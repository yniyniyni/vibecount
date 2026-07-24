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
