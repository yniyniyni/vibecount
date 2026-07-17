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

    /// Stub that answers auth with a fixed token and delegates Firestore
    /// requests to `firestoreHandler`.
    private func stubAuthAndFirestore(
        _ firestoreHandler: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) {
        StubURLProtocol.handler = { request in
            if request.url!.host!.contains("identitytoolkit") {
                return (200, Self.json([
                    "idToken": "token-1", "refreshToken": "refresh-1",
                    "localId": "uid-1", "expiresIn": "3600",
                ]))
            }
            return firestoreHandler(request)
        }
    }

    private static let docsBase =
        "https://firestore.googleapis.com/v1/projects/test-project/databases/(default)/documents"

    func testGetDocumentReturnsNilOn404AndDocOn200() async throws {
        stubAuthAndFirestore { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
            if request.url!.absoluteString == "\(Self.docsBase)/users/missing" {
                return (404, Self.json(["error": ["message": "not found", "status": "NOT_FOUND"]]))
            }
            return (200, Self.json([
                "name": "projects/test-project/databases/(default)/documents/users/abc",
                "fields": ["displayName": ["stringValue": "Ilya"]],
            ]))
        }
        let missing = try await client.getDocument(path: "users/missing")
        XCTAssertNil(missing)
        let found = try await client.getDocument(path: "users/abc")
        XCTAssertEqual(found?.fields["displayName"], .string("Ilya"))
    }

    func testPatchDocumentSendsTypedFields() async throws {
        stubAuthAndFirestore { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try! JSONSerialization.jsonObject(
                with: StubURLProtocol.body(of: request)) as! [String: Any]
            let fields = body["fields"] as! [String: [String: Any]]
            XCTAssertEqual(fields["latestDailyTokens"]?["integerValue"] as? String, "5")
            return (200, Self.json(["name": "projects/p/databases/(default)/documents/users/abc"]))
        }
        try await client.patchDocument(
            path: "users/abc",
            fields: ["latestDailyTokens": .integer(5)])
    }

    func testCreateDocumentMapsConflictToAlreadyExists() async throws {
        stubAuthAndFirestore { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.absoluteString.contains("documentId=CODE1"))
            return (409, Self.json(["error": ["message": "exists", "status": "ALREADY_EXISTS"]]))
        }
        do {
            try await client.createDocument(
                parent: "inviteCodes", documentID: "CODE1",
                fields: ["uid": .string("uid-1")])
            XCTFail("expected alreadyExists")
        } catch let error as FirestoreClientError {
            XCTAssertEqual(error, .alreadyExists)
        }
    }

    func testPermissionDeniedMapsDistinctly() async throws {
        stubAuthAndFirestore { _ in
            (403, Self.json(["error": ["message": "denied", "status": "PERMISSION_DENIED"]]))
        }
        do {
            _ = try await client.getDocument(path: "users/other")
            XCTFail("expected permissionDenied")
        } catch let error as FirestoreClientError {
            XCTAssertEqual(error, .permissionDenied)
        }
    }

    func testListDocumentsParsesEmptyAndNonEmpty() async throws {
        stubAuthAndFirestore { request in
            if request.url!.absoluteString.contains("empty") {
                return (200, Self.json([:]))  // Firestore omits "documents" when none
            }
            return (200, Self.json(["documents": [
                ["name": "projects/p/databases/(default)/documents/users/me/friends/f1",
                 "fields": ["inviteCode": ["stringValue": "C"]]],
            ]]))
        }
        let empty = try await client.listDocuments(path: "users/empty/friends")
        XCTAssertEqual(empty, [])
        let one = try await client.listDocuments(path: "users/me/friends")
        XCTAssertEqual(one.map(\.documentID), ["f1"])
    }

    func testBatchGetKeysByRelativePathWithNilForMissing() async throws {
        stubAuthAndFirestore { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("documents:batchGet"))
            let body = try! JSONSerialization.jsonObject(
                with: StubURLProtocol.body(of: request)) as! [String: Any]
            let names = body["documents"] as! [String]
            XCTAssertTrue(names.allSatisfy { $0.hasPrefix("projects/test-project/") })
            let payload: [[String: Any]] = [
                ["found": ["name": "projects/test-project/databases/(default)/documents/users/a",
                           "fields": ["displayName": ["stringValue": "A"]]],
                 "readTime": "2027-01-01T00:00:00Z"],
                ["missing": "projects/test-project/databases/(default)/documents/users/b",
                 "readTime": "2027-01-01T00:00:00Z"],
            ]
            return (200, try! JSONSerialization.data(withJSONObject: payload))
        }
        let result = try await client.batchGet(paths: ["users/a", "users/b"])
        XCTAssertEqual(result["users/a"]??.fields["displayName"], .string("A"))
        XCTAssertEqual(result["users/b"], .some(nil))
    }

    func testExpiredTokenIsRefreshedOnceAndRequestRetried() async throws {
        // First Firestore call answers 401; the client must refresh and retry.
        nonisolated(unsafe) var firestoreCalls = 0
        StubURLProtocol.handler = { request in
            let host = request.url!.host!
            if host.contains("identitytoolkit") {
                return (200, Self.json([
                    "idToken": "token-1", "refreshToken": "refresh-1",
                    "localId": "uid-1", "expiresIn": "3600",
                ]))
            }
            if host.contains("securetoken") {
                return (200, Self.json([
                    "id_token": "token-2", "refresh_token": "refresh-2",
                    "user_id": "uid-1", "expires_in": "3600",
                ]))
            }
            firestoreCalls += 1
            if firestoreCalls == 1 {
                return (401, Self.json(["error": ["message": "expired", "status": "UNAUTHENTICATED"]]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-2")
            return (200, Self.json([
                "name": "projects/test-project/databases/(default)/documents/users/abc",
                "fields": [:],
            ]))
        }
        let doc = try await client.getDocument(path: "users/abc")
        XCTAssertNotNil(doc)
        XCTAssertEqual(firestoreCalls, 2)
    }
}
