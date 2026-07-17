import XCTest
@testable import VibeCount

final class FirebaseConfigResolveTests: XCTestCase {
    private var directory: URL!
    private var store: SyncConfigStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = SyncConfigStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testStoredConfigWinsOverBundled() throws {
        try store.save(SyncConfig(projectID: "stored-proj", apiKey: "stored-key", hostInviteCode: nil))
        let bundled = FirebaseConfig(apiKey: "bundled-key", projectID: "bundled-proj")
        let resolved = FirebaseConfig.resolve(store: store, bundled: bundled)
        XCTAssertEqual(resolved, FirebaseConfig(apiKey: "stored-key", projectID: "stored-proj"))
    }

    func testFallsBackToBundledWhenNothingStored() {
        let bundled = FirebaseConfig(apiKey: "bundled-key", projectID: "bundled-proj")
        XCTAssertEqual(FirebaseConfig.resolve(store: store, bundled: bundled), bundled)
    }

    func testNilWhenNeitherPresent() {
        XCTAssertNil(FirebaseConfig.resolve(store: store, bundled: nil))
    }
}
