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

extension FirebaseCLITests {
    private func cli(_ results: [CommandResult],
                     _ recorder: StubRunner.Recorder = .init()) -> FirebaseCLI {
        FirebaseCLI(binaryPath: "/bin/firebase", token: "tok",
                    runner: StubRunner(results: results, recorder: recorder))
    }

    func testSdkConfigParsesProjectAndKey() async throws {
        let json = """
        {"result":{"sdkConfig":{"projectId":"vibecount-abc","apiKey":"AIzaXYZ"}}}
        """
        let config = try await cli([CommandResult(exitCode: 0, stdout: json, stderr: "")])
            .sdkConfig(projectID: "vibecount-abc", appID: "1:2:web:3")
        XCTAssertEqual(config, FirebaseConfig(apiKey: "AIzaXYZ", projectID: "vibecount-abc"))
    }

    func testCreateWebAppParsesAppId() async throws {
        let json = #"{"result":{"appId":"1:2:web:3","displayName":"VibeCount"}}"#
        let appID = try await cli([CommandResult(exitCode: 0, stdout: json, stderr: "")])
            .createWebApp(projectID: "p", displayName: "VibeCount")
        XCTAssertEqual(appID, "1:2:web:3")
    }

    func testListProjectsParsesArray() async throws {
        let json = """
        {"result":[{"projectId":"p1","displayName":"One"},{"projectId":"p2","displayName":"Two"}]}
        """
        let projects = try await cli([CommandResult(exitCode: 0, stdout: json, stderr: "")])
            .listProjects()
        XCTAssertEqual(projects, [
            FirebaseProjectSummary(projectID: "p1", displayName: "One"),
            FirebaseProjectSummary(projectID: "p2", displayName: "Two"),
        ])
    }

    func testCreateProjectAlreadyExistsIsSuccess() async throws {
        let runner = cli([CommandResult(
            exitCode: 1, stdout: "",
            stderr: "Error: Failed to create project because there is already a project with ID p")])
        // Should NOT throw — idempotent.
        try await runner.createProject(projectID: "p", displayName: "VibeCount")
    }

    func testDeployRulesBuildsExpectedArgs() async throws {
        let recorder = StubRunner.Recorder()
        let runner = cli([CommandResult(exitCode: 0, stdout: "", stderr: "")], recorder)
        try await runner.deployRules(projectID: "vibecount-abc", rulesPath: "/tmp/firebase.json")
        let args = recorder.calls.first?.arguments ?? []
        XCTAssertTrue(args.contains("deploy"))
        XCTAssertTrue(args.contains("--only"))
        XCTAssertTrue(args.contains("firestore:rules"))
        XCTAssertEqual(args.firstIndex(of: "--project").map { args[$0 + 1] }, "vibecount-abc")
        XCTAssertEqual(args.firstIndex(of: "--config").map { args[$0 + 1] }, "/tmp/firebase.json")
    }

    func testCreateFirestorePassesLocationFlag() async throws {
        let recorder = StubRunner.Recorder()
        let runner = cli([CommandResult(exitCode: 0, stdout: "", stderr: "")], recorder)
        try await runner.createFirestore(projectID: "p", location: "eur3")
        let args = recorder.calls.first?.arguments ?? []
        XCTAssertTrue(args.contains("firestore:databases:create"))
        XCTAssertTrue(args.contains("eur3"))
        XCTAssertTrue(args.contains("p"))
    }
}
