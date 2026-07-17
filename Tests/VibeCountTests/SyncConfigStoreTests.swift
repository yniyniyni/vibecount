// Tests/VibeCountTests/SyncConfigStoreTests.swift
import XCTest
@testable import VibeCount

final class SyncConfigStoreTests: XCTestCase {
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

    func testLoadReturnsNilWhenFileMissing() {
        XCTAssertNil(store.load())
    }

    func testSaveLoadRoundTrip() throws {
        let config = SyncConfig(projectID: "my-proj", apiKey: "AIzaKey", hostInviteCode: "ABCDEFGH23456789")
        try store.save(config)
        XCTAssertEqual(store.load(), config)
    }

    func testRoundTripWithoutInviteCode() throws {
        let config = SyncConfig(projectID: "my-proj", apiKey: "AIzaKey", hostInviteCode: nil)
        try store.save(config)
        XCTAssertEqual(store.load(), config)
    }

    func testLoadReturnsNilOnCorruptFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("sync-config.json"))
        XCTAssertNil(store.load())
    }

    func testClearRemovesFile() throws {
        try store.save(SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil))
        store.clear()
        XCTAssertNil(store.load())
    }

    func testLegacyConfigWithoutGoogleFieldsDecodes() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"projectID":"p","apiKey":"k"}"#.utf8)
            .write(to: directory.appendingPathComponent("sync-config.json"))
        let loaded = store.load()
        XCTAssertEqual(loaded, SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil))
        XCTAssertNil(loaded?.googleClientID)
        XCTAssertNil(loaded?.googleClientSecret)
    }

    func testGoogleFieldsRoundTrip() throws {
        var config = SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil)
        config.googleClientID = "cid.apps.googleusercontent.com"
        config.googleClientSecret = "GOCSPX-x"
        try store.save(config)
        XCTAssertEqual(store.load(), config)
    }
}
