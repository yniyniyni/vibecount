import XCTest
@testable import VibeCount

final class FirebaseCLITests: XCTestCase {
    /// Records calls and returns scripted results, so no real subprocess runs.
    struct StubRunner: CommandRunning {
        let results: [CommandResult]
        let recorder: Recorder
        final class Recorder: @unchecked Sendable {
            var calls: [(executable: String, arguments: [String], environment: [String: String])] = []
        }
        func run(executable: String, arguments: [String],
                 environment: [String: String]) async throws -> CommandResult {
            recorder.calls.append((executable, arguments, environment))
            return results[min(recorder.calls.count - 1, results.count - 1)]
        }
    }

    func testLocateFindsBinaryInCommonDirectory() {
        let found = FirebaseCLI.locate(
            pathVariable: "/nowhere:/also-nowhere",
            extraDirectories: ["/opt/homebrew/bin"],
            fileExists: { $0 == "/opt/homebrew/bin/firebase" })
        XCTAssertEqual(found, "/opt/homebrew/bin/firebase")
    }

    func testLocateReturnsNilWhenAbsent() {
        let found = FirebaseCLI.locate(
            pathVariable: "/nowhere", extraDirectories: [], fileExists: { _ in false })
        XCTAssertNil(found)
    }

    func testVersionReturnsTrimmedStdoutAndInjectsToken() async throws {
        let recorder = StubRunner.Recorder()
        let runner = StubRunner(
            results: [CommandResult(exitCode: 0, stdout: "13.0.1\n", stderr: "")],
            recorder: recorder)
        let cli = FirebaseCLI(binaryPath: "/bin/firebase", token: "tok", runner: runner)
        let version = try await cli.version()
        XCTAssertEqual(version, "13.0.1")
        XCTAssertEqual(recorder.calls.first?.arguments, ["--version"])
        XCTAssertEqual(recorder.calls.first?.environment["FIREBASE_TOKEN"], "tok")
    }

    func testNonZeroExitThrowsCommandFailed() async {
        let runner = StubRunner(
            results: [CommandResult(exitCode: 1, stdout: "", stderr: "boom")],
            recorder: .init())
        let cli = FirebaseCLI(binaryPath: "/bin/firebase", token: "tok", runner: runner)
        do {
            _ = try await cli.version()
            XCTFail("expected throw")
        } catch let error as FirebaseCLIError {
            XCTAssertEqual(error, .commandFailed(step: "version", message: "boom"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    /// Real-subprocess coverage for ProcessRunner itself (the stub above never
    /// exercises Process/Pipe). Guards against the stdout/stderr pipe deadlock
    /// and confirms exit codes/output still flow through correctly now that
    /// the reads happen off the cooperative thread pool.
    func testProcessRunnerRunsRealEchoAndCapturesOutput() async throws {
        let echoPath = "/bin/echo"
        guard FileManager.default.fileExists(atPath: echoPath) else {
            throw XCTSkip("\(echoPath) not present on this runner")
        }
        let runner = ProcessRunner()
        let result = try await runner.run(executable: echoPath, arguments: ["hello"], environment: [:])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testProcessRunnerReportsNonZeroExitCode() async throws {
        let shPath = "/bin/sh"
        guard FileManager.default.fileExists(atPath: shPath) else {
            throw XCTSkip("\(shPath) not present on this runner")
        }
        let runner = ProcessRunner()
        let result = try await runner.run(
            executable: shPath, arguments: ["-c", "exit 3"], environment: [:])
        XCTAssertEqual(result.exitCode, 3)
    }
}
