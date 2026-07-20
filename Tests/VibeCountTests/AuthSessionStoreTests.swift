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

        // A pre-existing wider-permission file (pre-fix build, restored
        // backup) must come back to 0600 on the next save.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try store.save(StoredAuthSession(uid: "abc", refreshToken: "r3"))
        let attrs3 = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs3[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
        XCTAssertEqual(store.load()?.refreshToken, "r3")
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

    func testPerProjectStoresAreIsolated() throws {
        let projectA = AuthSessionStore(directory: directory, projectID: "proj-a")
        let projectB = AuthSessionStore(directory: directory, projectID: "proj-b")
        try projectA.save(StoredAuthSession(uid: "ua", refreshToken: "ra"))
        XCTAssertNil(projectB.load())
        XCTAssertNil(store.load(), "legacy file must stay untouched")
        XCTAssertEqual(projectA.fileURL.lastPathComponent, "firebase-auth-proj-a.json")
        XCTAssertEqual(projectA.load(), StoredAuthSession(uid: "ua", refreshToken: "ra"))
    }

    func testProjectIDIsEncodedInjectivelyForFileName() {
        // Plain Firebase-style ids keep their pre-existing file names.
        XCTAssertEqual(
            AuthSessionStore(directory: directory, projectID: "proj-a").fileURL.lastPathComponent,
            "firebase-auth-proj-a.json")
        // Hostile characters are percent-encoded, not dropped.
        let odd = AuthSessionStore(directory: directory, projectID: "p/../x y")
        XCTAssertEqual(odd.fileURL.lastPathComponent, "firebase-auth-p%2F%2E%2E%2Fx%20y.json")
        // Distinct project ids can never collide onto one session file.
        let dotted = AuthSessionStore(directory: directory, projectID: "my.project")
        let plain = AuthSessionStore(directory: directory, projectID: "myproject")
        XCTAssertNotEqual(dotted.fileURL, plain.fileURL)
    }

    func testAdoptLegacySessionMovesFileOnce() throws {
        try store.save(StoredAuthSession(uid: "u1", refreshToken: "r1"))
        AuthSessionStore.adoptLegacySession(for: "proj-a", directory: directory)
        let current = AuthSessionStore(directory: directory, projectID: "proj-a")
        XCTAssertEqual(current.load(), StoredAuthSession(uid: "u1", refreshToken: "r1"))
        XCTAssertNil(store.load(), "legacy file is consumed by the move")

        // A later legacy file must not clobber an existing per-project session.
        try store.save(StoredAuthSession(uid: "u2", refreshToken: "r2"))
        AuthSessionStore.adoptLegacySession(for: "proj-a", directory: directory)
        XCTAssertEqual(current.load()?.uid, "u1")
    }

    func testLegacySessionFileWithoutLinkedEmailDecodes() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"uid":"u1","refreshToken":"r1"}"#.utf8)
            .write(to: directory.appendingPathComponent("firebase-auth.json"))
        XCTAssertEqual(store.load(), StoredAuthSession(uid: "u1", refreshToken: "r1"))
        XCTAssertNil(store.load()?.linkedEmail)
    }

    func testLinkedEmailRoundTrips() throws {
        let session = StoredAuthSession(uid: "u1", refreshToken: "r1", linkedEmail: "a@b.c")
        try store.save(session)
        XCTAssertEqual(store.load(), session)
    }
}
