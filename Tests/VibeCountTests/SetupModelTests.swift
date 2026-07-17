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
        linkedEmail: String? = nil,
        validateResult: Result<String, ConfigValidationError> = .success("uid-1"),
        commitError: Error? = nil,
        fetchOwnInviteCode: @escaping () -> String? = { nil },
        signInResult: Result<String?, Error> = .success("a@b.c"),
        box: Box = Box()
    ) -> SetupModel {
        SetupModel(
            route: route, currentConfig: currentConfig, ownInviteCode: ownInviteCode,
            linkedEmail: linkedEmail,
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
                signInWithGoogle: {
                    switch signInResult {
                    case .success(let email): return email
                    case .failure(let error): throw error
                    }
                },
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

    func testSubmitHostCarriesGooglePair() async {
        let box = Box()
        let model = makeModel(route: .host, box: box)
        model.projectID = "p"
        model.apiKey = "k"
        model.googleClientIDField = " cid "
        model.googleClientSecretField = " sec "
        await model.submitHost()
        XCTAssertEqual(box.recorder.committed.first?.googleClientID, "cid")
        XCTAssertEqual(box.recorder.committed.first?.googleClientSecret, "sec")
    }

    func testSubmitHostRejectsHalfGooglePair() async {
        let box = Box()
        let model = makeModel(route: .host, box: box)
        model.projectID = "p"
        model.apiKey = "k"
        model.googleClientIDField = "cid"
        await model.submitHost()
        guard case .failure = model.phase else { return XCTFail("expected failure") }
        XCTAssertEqual(box.recorder.validated, [])
    }

    func testSubmitJoinCarriesGooglePairFromLink() async {
        let box = Box()
        let model = makeModel(route: .join, box: box)
        model.joinText = "vibecount://join?v=1&p=p&k=k&gi=cid&gs=sec"
        await model.submitJoin()
        XCTAssertEqual(box.recorder.committed.first?.googleClientID, "cid")
        XCTAssertEqual(box.recorder.committed.first?.googleClientSecret, "sec")
    }

    func testShareLinkIncludesGooglePair() {
        var config = SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil)
        config.googleClientID = "cid"
        config.googleClientSecret = "sec"
        let model = makeModel(currentConfig: config, ownInviteCode: "ABCDEFGH23456789")
        XCTAssertTrue(model.shareLink?.contains("gi=cid") == true)
        XCTAssertTrue(model.shareLink?.contains("gs=sec") == true)
    }

    func testGoogleAvailabilityRules() {
        var config = SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil)
        XCTAssertFalse(makeModel(currentConfig: config).googleSignInAvailable, "no client pair")
        config.googleClientID = "cid"
        config.googleClientSecret = "sec"
        XCTAssertTrue(makeModel(currentConfig: config).googleSignInAvailable)
        XCTAssertFalse(makeModel(currentConfig: config, linkedEmail: "a@b.c").googleSignInAvailable,
                       "already linked")
        XCTAssertFalse(makeModel(currentConfig: nil).googleSignInAvailable, "no config")
    }

    func testSignInWithGoogleSuccessSetsEmail() async {
        var config = SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil)
        config.googleClientID = "cid"
        config.googleClientSecret = "sec"
        let model = makeModel(currentConfig: config, signInResult: .success("a@b.c"))
        await model.signInWithGoogle()
        XCTAssertEqual(model.linkedEmail, "a@b.c")
        XCTAssertNil(model.signInError)
        XCTAssertFalse(model.googleSignInAvailable)
    }

    func testSignInWithGoogleCancelledStaysQuiet() async {
        var config = SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil)
        config.googleClientID = "cid"
        config.googleClientSecret = "sec"
        let model = makeModel(currentConfig: config, signInResult: .failure(GoogleSignInError.cancelled))
        await model.signInWithGoogle()
        XCTAssertNil(model.linkedEmail)
        XCTAssertNil(model.signInError, "cancellation must not surface an error")
    }

    func testSignInWithGoogleFailureSurfaces() async {
        var config = SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil)
        config.googleClientID = "cid"
        config.googleClientSecret = "sec"
        let model = makeModel(currentConfig: config, signInResult: .failure(GoogleSignInError.server("boom")))
        await model.signInWithGoogle()
        XCTAssertNil(model.linkedEmail)
        XCTAssertEqual(model.signInError, GoogleSignInError.server("boom").localizedDescription)
    }

    func testSubmitDefaultCloudCommitsSharedProjectAndRequiresGoogle() async {
        let box = Box()
        let model = makeModel(route: .welcome, signInResult: .success("a@b.c"), box: box)
        await model.submitDefaultCloud()
        XCTAssertEqual(model.phase, SetupModel.Phase.success)
        XCTAssertEqual(box.recorder.validated, [DefaultSyncProject.firebaseConfig])
        XCTAssertEqual(box.recorder.committed, [DefaultSyncProject.syncConfig])
        XCTAssertTrue(model.isOnDefaultCloud)
        XCTAssertEqual(model.linkedEmail, "a@b.c")
        XCTAssertFalse(model.googleSignInRequired)
    }

    func testSubmitDefaultCloudStaysNeedsGoogleWhenSignInCancelled() async {
        let box = Box()
        let model = makeModel(
            route: .welcome,
            signInResult: .failure(GoogleSignInError.cancelled),
            box: box)
        await model.submitDefaultCloud()
        XCTAssertEqual(model.phase, SetupModel.Phase.needsGoogleSignIn)
        XCTAssertEqual(box.recorder.committed, [DefaultSyncProject.syncConfig])
        XCTAssertNil(model.linkedEmail)
        XCTAssertTrue(model.googleSignInRequired)
        XCTAssertEqual(model.signInError, "Google sign-in is required for VibeCount cloud.")
    }

    func testSubmitDefaultCloudSurfacesValidationFailure() async {
        let box = Box()
        let model = makeModel(
            route: .welcome,
            validateResult: .failure(.authRejected("API_KEY_INVALID")),
            box: box)
        await model.submitDefaultCloud()
        guard case .failure(let message) = model.phase else {
            return XCTFail("expected failure, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("API_KEY_INVALID") || message.contains("Sign-in"))
        XCTAssertEqual(box.recorder.committed, [])
    }

    func testIsOnDefaultCloud() {
        XCTAssertFalse(makeModel(currentConfig: nil).isOnDefaultCloud)
        XCTAssertTrue(makeModel(currentConfig: DefaultSyncProject.syncConfig, linkedEmail: "a@b.c").isOnDefaultCloud)
        let other = SyncConfig(projectID: "other", apiKey: "k", hostInviteCode: nil)
        XCTAssertFalse(makeModel(currentConfig: other).isOnDefaultCloud)
    }

    func testGoogleSignInRequiredOnlyOnCloudWithoutLink() {
        XCTAssertTrue(makeModel(currentConfig: DefaultSyncProject.syncConfig).googleSignInRequired)
        XCTAssertFalse(makeModel(
            currentConfig: DefaultSyncProject.syncConfig, linkedEmail: "a@b.c").googleSignInRequired)
        var selfHost = SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil)
        selfHost.googleClientID = "cid"
        selfHost.googleClientSecret = "sec"
        XCTAssertFalse(makeModel(currentConfig: selfHost).googleSignInRequired)
    }

    func testCloudCancelSurfacesRequiredError() async {
        let model = makeModel(
            currentConfig: DefaultSyncProject.syncConfig,
            signInResult: .failure(GoogleSignInError.cancelled))
        await model.signInWithGoogle()
        XCTAssertNil(model.linkedEmail)
        XCTAssertEqual(model.signInError, "Google sign-in is required for VibeCount cloud.")
        XCTAssertEqual(model.phase, SetupModel.Phase.needsGoogleSignIn)
    }

    func testInitOnCloudWithoutLinkStartsNeedsGoogle() {
        let model = makeModel(route: .settings, currentConfig: DefaultSyncProject.syncConfig)
        XCTAssertEqual(model.phase, SetupModel.Phase.needsGoogleSignIn)
        XCTAssertTrue(model.googleSignInAvailable)
    }

    func testJoinCloudLinkAlsoRequiresGoogle() async {
        let box = Box()
        let model = makeModel(
            route: .join,
            signInResult: .failure(GoogleSignInError.cancelled),
            box: box)
        model.joinText = "vibecount://join?v=1&p=\(DefaultSyncProject.projectID)&k=\(DefaultSyncProject.apiKey)"
        await model.submitJoin()
        XCTAssertEqual(model.phase, SetupModel.Phase.needsGoogleSignIn)
        XCTAssertEqual(box.recorder.committed.first?.googleClientID, DefaultSyncProject.googleClientID)
        XCTAssertTrue(model.googleSignInRequired)
    }
}
