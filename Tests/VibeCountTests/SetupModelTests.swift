import XCTest
@testable import VibeCount

@MainActor
final class SetupModelTests: XCTestCase {
    private struct Recorder {
        var validated: [FirebaseConfig] = []
        var committed: [SyncConfig] = []
    }

    private final class Box: @unchecked Sendable { var recorder = Recorder() }

    private func makeModel(
        route: SetupModel.Route = .welcome,
        currentConfig: SyncConfig? = nil,
        ownInviteCode: String? = nil,
        validateResult: Result<String, ConfigValidationError> = .success("uid-1"),
        commitError: Error? = nil,
        fetchOwnInviteCode: @escaping () -> String? = { nil },
        box: Box = Box()
    ) -> SetupModel {
        SetupModel(
            route: route, currentConfig: currentConfig, ownInviteCode: ownInviteCode,
            actions: SetupActions(
                validate: { config, store in
                    box.recorder.validated.append(config)
                    if case .success = validateResult {
                        try? store.save(StoredAuthSession(uid: "uid-1", refreshToken: "r1"))
                    }
                    return validateResult
                },
                commit: { config, _ in
                    if let commitError { throw commitError }
                    box.recorder.committed.append(config)
                },
                fetchOwnInviteCode: fetchOwnInviteCode,
                dismiss: {}))
    }

    func testSubmitHostValidatesThenCommitsAndSucceeds() async {
        let box = Box()
        let model = makeModel(route: .host, fetchOwnInviteCode: { "ABCDEFGH23456789" }, box: box)
        model.projectID = " my-proj "
        model.apiKey = " AIzaKey "
        await model.submitHost()
        XCTAssertEqual(model.phase, .success)
        XCTAssertEqual(box.recorder.validated, [FirebaseConfig(apiKey: "AIzaKey", projectID: "my-proj")])
        // Host config carries no hostInviteCode — hosts don't friend themselves.
        XCTAssertEqual(box.recorder.committed, [SyncConfig(projectID: "my-proj", apiKey: "AIzaKey", hostInviteCode: nil)])
        // The success footer needs the NEW config's share link, not a stale
        // one captured at window construction.
        XCTAssertNotNil(model.shareLink)
        XCTAssertTrue(model.shareLink?.contains("my-proj") ?? false)
    }

    func testSubmitHostFailureSurfacesErrorAndSkipsCommit() async {
        let box = Box()
        let model = makeModel(route: .host, validateResult: .failure(.firestoreMissing), box: box)
        model.projectID = "p"
        model.apiKey = "k"
        await model.submitHost()
        XCTAssertEqual(model.phase, .failure(ConfigValidationError.firestoreMissing.localizedDescription))
        XCTAssertEqual(box.recorder.committed, [])
    }

    func testSubmitHostCommitFailureSurfacesError() async {
        let box = Box()
        let model = makeModel(
            route: .host, commitError: CocoaError(.fileWriteUnknown), box: box)
        model.projectID = "my-proj"
        model.apiKey = "AIzaKey"
        await model.submitHost()
        guard case .failure = model.phase else {
            return XCTFail("expected failure, got \(model.phase)")
        }
        // Validation still ran (and succeeded) before the commit threw — the
        // failure is specifically a commit failure, not a validation failure.
        XCTAssertEqual(box.recorder.validated, [FirebaseConfig(apiKey: "AIzaKey", projectID: "my-proj")])
        XCTAssertEqual(box.recorder.committed, [])
    }

    func testSubmitHostRejectsEmptyFieldsWithoutValidating() async {
        let box = Box()
        let model = makeModel(route: .host, box: box)
        await model.submitHost()
        guard case .failure = model.phase else { return XCTFail("expected failure, got \(model.phase)") }
        XCTAssertEqual(box.recorder.validated, [])
    }

    func testSubmitJoinParsesLinkAndCommitsWithHostCode() async {
        let box = Box()
        let model = makeModel(route: .join, box: box)
        model.joinText = "vibecount://join?v=1&p=host-proj&k=host-key&c=ABCD-EFGH-2345-6789"
        await model.submitJoin()
        XCTAssertEqual(model.phase, .success)
        XCTAssertEqual(box.recorder.committed, [SyncConfig(
            projectID: "host-proj", apiKey: "host-key", hostInviteCode: "ABCDEFGH23456789")])
    }

    func testSubmitJoinBadLinkFailsWithoutValidating() async {
        let box = Box()
        let model = makeModel(route: .join, box: box)
        model.joinText = "https://nope"
        await model.submitJoin()
        XCTAssertEqual(model.phase, .failure(JoinLinkError.notAJoinLink.localizedDescription))
        XCTAssertEqual(box.recorder.validated, [])
    }

    func testIsSwitchingBackends() {
        let current = SyncConfig(projectID: "old", apiKey: "k", hostInviteCode: nil)
        XCTAssertTrue(makeModel(currentConfig: current).isSwitchingBackends)
        XCTAssertFalse(makeModel(currentConfig: nil).isSwitchingBackends)
    }

    func testShareLinkNilWithoutConfigAndPresentWithIt() {
        XCTAssertNil(makeModel().shareLink)
        let model = makeModel(
            currentConfig: SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil),
            ownInviteCode: "ABCDEFGH23456789")
        XCTAssertEqual(model.shareLink, "vibecount://join?v=1&p=p&k=k&c=ABCDEFGH23456789")
    }

    func testPrefillJoinLink() {
        let model = makeModel()
        model.prefill(joinLink: JoinLink(projectID: "p", apiKey: "k", hostInviteCode: nil))
        XCTAssertEqual(model.route, .join)
        XCTAssertEqual(model.joinText, "vibecount://join?v=1&p=p&k=k")
    }
}
