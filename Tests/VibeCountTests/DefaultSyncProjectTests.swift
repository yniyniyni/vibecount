import XCTest
@testable import VibeCount

final class DefaultSyncProjectTests: XCTestCase {
    func testSharedCredentialsAreNonEmpty() {
        XCTAssertEqual(DefaultSyncProject.projectID, "vibe-count-app-0703")
        XCTAssertFalse(DefaultSyncProject.apiKey.isEmpty)
        XCTAssertTrue(DefaultSyncProject.apiKey.hasPrefix("AIza"))
        XCTAssertFalse(DefaultSyncProject.googleClientID.isEmpty)
        XCTAssertFalse(DefaultSyncProject.googleClientSecret.isEmpty)
    }

    func testSyncConfigCarriesGoogleOAuthPair() {
        let sync = DefaultSyncProject.syncConfig
        let firebase = DefaultSyncProject.firebaseConfig
        XCTAssertEqual(sync.projectID, firebase.projectID)
        XCTAssertEqual(sync.apiKey, firebase.apiKey)
        XCTAssertNil(sync.hostInviteCode)
        XCTAssertEqual(sync.googleClientID, DefaultSyncProject.googleClientID)
        XCTAssertEqual(sync.googleClientSecret, DefaultSyncProject.googleClientSecret)
    }

    func testMatchesByProjectID() {
        XCTAssertTrue(DefaultSyncProject.matches(DefaultSyncProject.syncConfig))
        XCTAssertFalse(DefaultSyncProject.matches(nil))
        XCTAssertFalse(DefaultSyncProject.matches(
            SyncConfig(projectID: "other", apiKey: "k", hostInviteCode: nil)))
    }

    func testEnrichedInjectsOAuthOnCloudConfigs() {
        var bare = SyncConfig(projectID: DefaultSyncProject.projectID, apiKey: "k", hostInviteCode: nil)
        bare = DefaultSyncProject.enriched(bare)
        XCTAssertEqual(bare.googleClientID, DefaultSyncProject.googleClientID)
        XCTAssertEqual(bare.googleClientSecret, DefaultSyncProject.googleClientSecret)

        let other = SyncConfig(projectID: "other", apiKey: "k", hostInviteCode: nil)
        XCTAssertNil(DefaultSyncProject.enriched(other).googleClientID)
    }
}
