import Foundation

/// Result of running an external command.
struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs external commands. Injected so tests never spawn real processes.
protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String],
             environment: [String: String]) async throws -> CommandResult
}

/// Real runner backed by Foundation.Process. Inherits the caller's environment
/// and overlays the supplied keys (so PATH stays intact and FIREBASE_TOKEN is
/// added on top).
struct ProcessRunner: CommandRunning {
    /// Mutable scratch space for the two background reader work items below.
    /// Each item writes to exactly one field; `DispatchGroup.wait()` supplies
    /// the happens-before edge that makes reading both fields afterwards safe,
    /// so the checked-Sendable escape hatch here doesn't hide a real race.
    private final class CapturedOutput: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
    }

    func run(executable: String, arguments: [String],
             environment: [String: String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                let out = Pipe(); let err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain stdout and stderr concurrently: reading either pipe to
                // EOF sequentially risks deadlock if the child fills the other
                // pipe's kernel buffer (~64KB) and blocks on that write while
                // we're still blocked reading the first one.
                let captured = CapturedOutput()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    captured.stdout = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    captured.stderr = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: captured.stdout, as: UTF8.self),
                    stderr: String(decoding: captured.stderr, as: UTF8.self)))
            }
        }
    }
}
