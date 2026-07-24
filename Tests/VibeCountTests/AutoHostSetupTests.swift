import XCTest
@testable import VibeCount

@MainActor
final class AutoHostSetupTests: XCTestCase {
    private final class MockCLI: FirebaseCLIRunning, @unchecked Sendable {
        var failCreateFirestore = false
        var createdWebAppID = "1:2:web:3"
        var sdkConfigResult = FirebaseConfig(apiKey: "AIzaKey", projectID: "vibecount-new")
        var calls: [String] = []
        func version() async throws -> String { calls.append("version"); return "13.0.0" }
        func createProject(projectID: String, displayName: String) async throws { calls.append("createProject:\(projectID)") }
        func listProjects() async throws -> [FirebaseProjectSummary] { [] }
        func createFirestore(projectID: String, location: String) async throws {
            calls.append("createFirestore:\(location)")
            if failCreateFirestore { throw FirebaseCLIError.commandFailed(step: "createFirestore", message: "nope") }
        }
        func deployRules(projectID: String, rulesPath: String) async throws { calls.append("deployRules") }
        func createWebApp(projectID: String, displayName: String) async throws -> String { calls.append("createWebApp"); return createdWebAppID }
        func sdkConfig(projectID: String, appID: String) async throws -> FirebaseConfig { calls.append("sdkConfig"); return sdkConfigResult }
    }

    private final class Box: @unchecked Sendable {
        var committed: [SyncConfig] = []
        var enabledFor: [String] = []
    }

    private func makeSetup(cli: MockCLI, box: Box,
                           commitResult: Result<Void, ConfigValidationError> = .success(())) -> AutoHostSetup {
        AutoHostSetup(dependencies: AutoSetupDependencies(
            locateCLI: { "/bin/firebase" },
            makeCLI: { _, _ in cli },
            signIn: { GoogleTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600) },
            accessToken: { _ in "at" },
            enableAnonymous: { projectID, _ in box.enabledFor.append(projectID) },
            rulesPath: { "/tmp/firestore.rules" },
            commit: { config in box.committed.append(config); return commitResult },
            newProjectID: { "vibecount-new" }))
    }

    func testHappyPathRunsAllStepsAndCommits() async {
        let cli = MockCLI(); let box = Box()
        let setup = makeSetup(cli: cli, box: box)
        await setup.run()
        XCTAssertEqual(setup.states[.commit], .done)
        XCTAssertTrue(setup.finished)
        XCTAssertEqual(box.enabledFor, ["vibecount-new"])
        XCTAssertEqual(box.committed, [SyncConfig(projectID: "vibecount-new", apiKey: "AIzaKey", hostInviteCode: nil)])
        XCTAssertTrue(cli.calls.contains("createProject:vibecount-new"))
        XCTAssertTrue(cli.calls.contains("createFirestore:eur3"))
    }

    func testCLIMissingSetsInstallNeededAndStops() async {
        let cli = MockCLI(); let box = Box()
        let setup = AutoHostSetup(dependencies: AutoSetupDependencies(
            locateCLI: { nil }, makeCLI: { _, _ in cli },
            signIn: { GoogleTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600) },
            accessToken: { _ in "at" }, enableAnonymous: { _, _ in },
            rulesPath: { "/tmp/x" }, commit: { _ in .success(()) }, newProjectID: { "p" }))
        await setup.run()
        XCTAssertTrue(setup.installNeeded)
        XCTAssertEqual(setup.states[.checkCLI], .failed("The firebase CLI isn't installed."))
        XCTAssertEqual(setup.states[.signIn], .pending)
        XCTAssertFalse(setup.finished)
    }

    func testFailureStopsChainAndMarksStepFailed() async {
        let cli = MockCLI(); cli.failCreateFirestore = true
        let box = Box()
        let setup = makeSetup(cli: cli, box: box)
        await setup.run()
        XCTAssertEqual(setup.states[.createFirestore], .failed("nope"))
        XCTAssertEqual(setup.states[.deployRules], .pending)
        XCTAssertFalse(setup.finished)
        XCTAssertTrue(box.committed.isEmpty)
    }

    func testExistingProjectSkipsCreateProject() async {
        let cli = MockCLI(); let box = Box()
        let setup = makeSetup(cli: cli, box: box)
        setup.existingProjectID = "my-existing"
        cli.sdkConfigResult = FirebaseConfig(apiKey: "AIzaKey", projectID: "my-existing")
        await setup.run()
        XCTAssertFalse(cli.calls.contains(where: { $0.hasPrefix("createProject") }))
        XCTAssertEqual(box.committed.first?.projectID, "my-existing")
    }

    func testRerunAfterFailureResumesAndCompletes() async {
        let cli = MockCLI(); cli.failCreateFirestore = true
        let box = Box()
        let setup = makeSetup(cli: cli, box: box)
        await setup.run()
        XCTAssertEqual(setup.states[.createFirestore], .failed("nope"))
        cli.failCreateFirestore = false
        await setup.run()          // resume
        XCTAssertTrue(setup.finished)
        // createProject not repeated (already done); createFirestore retried.
        XCTAssertEqual(cli.calls.filter { $0.hasPrefix("createProject") }.count, 1)
    }
}
