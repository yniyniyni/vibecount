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
    func run(executable: String, arguments: [String],
             environment: [String: String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}
