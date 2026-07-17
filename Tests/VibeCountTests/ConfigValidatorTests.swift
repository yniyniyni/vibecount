// Tests/VibeCountTests/ConfigValidatorTests.swift
import XCTest
@testable import VibeCount

final class ConfigValidatorTests: XCTestCase {
    private var directory: URL!
    private var authStore: AuthSessionStore!
    private var validator: ConfigValidator!
    private let config = FirebaseConfig(apiKey: "test-key", projectID: "test-project")

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        authStore = AuthSessionStore(directory: directory)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubURLProtocol.self]
        validator = ConfigValidator(session: URLSession(configuration: sessionConfig))
    }

    override func tearDownWithError() throws {
        StubURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func signUpOK(_ request: URLRequest) -> (Int, Data)? {
        guard request.url!.absoluteString.contains("accounts:signUp") else { return nil }
        return (200, json(["idToken": "t1", "refreshToken": "r1", "localId": "uid-1", "expiresIn": "3600"]))
    }

    func testValidConfigSucceedsAndPersistsSession() async throws {
        StubURLProtocol.handler = { request in
            if let response = Self.signUpOK(request) { return response }
            // batchGet answering "missing" — empty DB with rules deployed is valid.
            return (200, Self.json([["missing": "projects/test-project/databases/(default)/documents/users/uid-1"]]))
        }
        let result = await validator.validate(config, authStore: authStore)
        XCTAssertEqual(try result.get(), "uid-1")
        XCTAssertEqual(authStore.load(), StoredAuthSession(uid: "uid-1", refreshToken: "r1"))
    }

    func testAuthDisabledMapsToAuthRejected() async {
        StubURLProtocol.handler = { _ in
            (400, Self.json(["error": ["message": "CONFIGURATION_NOT_FOUND"]]))
        }
        let result = await validator.validate(config, authStore: authStore)
        XCTAssertEqual(result, .failure(.authRejected("CONFIGURATION_NOT_FOUND")))
    }

    func testMissingDatabaseMapsToFirestoreMissing() async {
        StubURLProtocol.handler = { request in
            if let response = Self.signUpOK(request) { return response }
            return (404, Self.json(["error": ["message": "The database (default) does not exist"]]))
        }
        let result = await validator.validate(config, authStore: authStore)
        XCTAssertEqual(result, .failure(.firestoreMissing))
    }

    func testLockedRulesMapToRulesRejected() async {
        StubURLProtocol.handler = { request in
            if let response = Self.signUpOK(request) { return response }
            return (403, Self.json(["error": ["message": "Missing or insufficient permissions."]]))
        }
        let result = await validator.validate(config, authStore: authStore)
        XCTAssertEqual(result, .failure(.rulesRejected))
    }

    func testServerErrorMapsToNetwork() async {
        StubURLProtocol.handler = { request in
            if let response = Self.signUpOK(request) { return response }
            return (503, Self.json(["error": ["message": "backend unavailable"]]))
        }
        let result = await validator.validate(config, authStore: authStore)
        XCTAssertEqual(result, .failure(.network("backend unavailable")))
    }
}
