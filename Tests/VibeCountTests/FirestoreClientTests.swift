import XCTest
@testable import VibeCount

/// Routes every request made through the stubbed URLSession to a test handler.
final class StubURLProtocol: URLProtocol {
    // Test-only global; tests run serially within this case.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession moves POST bodies into a stream; read it back for assertions.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class FirestoreClientTests: XCTestCase {
    private var directory: URL!
    private var store: AuthSessionStore!
    private var client: FirestoreClient!

    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = AuthSessionStore(directory: directory)
        client = FirestoreClient(
            config: FirebaseConfig(apiKey: "test-key", projectID: "test-project"),
            store: store,
            session: Self.stubbedSession())
    }

    override func tearDownWithError() throws {
        StubURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testSignInWithoutStoredSessionSignsUpAnonymouslyAndPersists() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.absoluteString.hasPrefix(
                "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=test-key"))
            return (200, Self.json([
                "idToken": "token-1", "refreshToken": "refresh-1",
                "localId": "uid-1", "expiresIn": "3600",
            ]))
        }
        let uid = try await client.signIn()
        XCTAssertEqual(uid, "uid-1")
        XCTAssertEqual(store.load(), StoredAuthSession(uid: "uid-1", refreshToken: "refresh-1"))
    }

    func testSignInWithStoredSessionRefreshesAndPersistsRotatedToken() async throws {
        try store.save(StoredAuthSession(uid: "uid-1", refreshToken: "refresh-1"))
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.absoluteString.hasPrefix(
                "https://securetoken.googleapis.com/v1/token?key=test-key"))
            let body = String(decoding: StubURLProtocol.body(of: request), as: UTF8.self)
            XCTAssertTrue(body.contains("refresh_token=refresh-1"))
            return (200, Self.json([
                "id_token": "token-2", "refresh_token": "refresh-2",
                "user_id": "uid-1", "expires_in": "3600",
            ]))
        }
        let uid = try await client.signIn()
        XCTAssertEqual(uid, "uid-1")
        XCTAssertEqual(store.load()?.refreshToken, "refresh-2", "rotated token must be persisted")
    }

    func testInvalidRefreshTokenFallsBackToFreshSignUp() async throws {
        try store.save(StoredAuthSession(uid: "uid-old", refreshToken: "revoked"))
        StubURLProtocol.handler = { request in
            if request.url!.host!.contains("securetoken") {
                return (400, Self.json(["error": ["message": "TOKEN_EXPIRED"]]))
            }
            return (200, Self.json([
                "idToken": "token-9", "refreshToken": "refresh-9",
                "localId": "uid-new", "expiresIn": "3600",
            ]))
        }
        let uid = try await client.signIn()
        XCTAssertEqual(uid, "uid-new")
        XCTAssertEqual(store.load()?.uid, "uid-new")
    }

    func testAuthErrorSurfacesServerMessage() async {
        StubURLProtocol.handler = { _ in
            (400, Self.json(["error": ["message": "CONFIGURATION_NOT_FOUND"]]))
        }
        do {
            _ = try await client.signIn()
            XCTFail("expected authFailed")
        } catch let error as FirestoreClientError {
            XCTAssertEqual(error, .authFailed("CONFIGURATION_NOT_FOUND"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testTransientRefreshFailureDoesNotWipeStoredIdentity() async throws {
        try store.save(StoredAuthSession(uid: "uid-1", refreshToken: "refresh-1"))
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.host!.contains("securetoken"),
                          "a transient refresh failure must not trigger a fresh signUp")
            return (503, Self.json(["error": ["message": "backend unavailable"]]))
        }
        do {
            _ = try await client.signIn()
            XCTFail("expected http error")
        } catch let error as FirestoreClientError {
            XCTAssertEqual(error, .http(503, "backend unavailable"))
        }
        XCTAssertEqual(store.load(), StoredAuthSession(uid: "uid-1", refreshToken: "refresh-1"),
                       "identity must survive a transient server failure")
    }
}
