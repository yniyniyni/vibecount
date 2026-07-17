import XCTest
@testable import VibeCount

final class AuthSessionStoreTests: XCTestCase {
    private var directory: URL!
    private var store: AuthSessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = AuthSessionStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testLoadReturnsNilWhenFileMissing() {
        XCTAssertNil(store.load())
    }

    func testSaveLoadRoundTrip() throws {
        let session = StoredAuthSession(uid: "abc", refreshToken: "r1")
        try store.save(session)
        XCTAssertEqual(store.load(), session)
    }

    func testSaveSetsOwnerOnlyPermissions() throws {
        try store.save(StoredAuthSession(uid: "abc", refreshToken: "r1"))
        let path = directory.appendingPathComponent("firebase-auth.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)

        // Verify the replace-existing path also preserves 0600 permissions
        try store.save(StoredAuthSession(uid: "abc", refreshToken: "r2"))
        let attrs2 = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs2[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
        XCTAssertEqual(store.load()?.refreshToken, "r2")
    }

    func testClearRemovesFile() throws {
        try store.save(StoredAuthSession(uid: "abc", refreshToken: "r1"))
        store.clear()
        XCTAssertNil(store.load())
    }

    func testCorruptFileLoadsAsNil() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("firebase-auth.json"))
        XCTAssertNil(store.load())
    }
}
