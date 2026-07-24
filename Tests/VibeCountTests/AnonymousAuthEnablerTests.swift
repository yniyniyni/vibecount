import XCTest
@testable import VibeCount

final class AnonymousAuthEnablerTests: XCTestCase {
    private func enabler() -> AnonymousAuthEnabler {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AnonymousAuthEnabler(session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.failure = nil
        super.tearDown()
    }

    func testEnableSendsPatchWithBearerAndBody() async throws {
        let box = CapturedRequest()
        StubURLProtocol.handler = { request in
            box.method = request.httpMethod
            box.url = request.url?.absoluteString
            box.authorization = request.value(forHTTPHeaderField: "Authorization")
            box.body = request.httpBodyData()
            return (200, Data("{}".utf8))
        }
        try await enabler().enable(projectID: "vibecount-abc", accessToken: "at")
        XCTAssertEqual(box.method, "PATCH")
        XCTAssertEqual(box.authorization, "Bearer at")
        XCTAssertTrue(box.url?.contains("/v2/projects/vibecount-abc/config") ?? false)
        XCTAssertTrue(box.url?.contains("updateMask=signIn.anonymous.enabled") ?? false)
        let json = try JSONSerialization.jsonObject(with: box.body ?? Data()) as? [String: Any]
        let signIn = json?["signIn"] as? [String: Any]
        let anonymous = signIn?["anonymous"] as? [String: Any]
        XCTAssertEqual(anonymous?["enabled"] as? Bool, true)
    }

    func testHttpErrorThrows() async {
        StubURLProtocol.handler = { _ in (403, Data(#"{"error":{"message":"PERMISSION_DENIED"}}"#.utf8)) }
        do {
            try await enabler().enable(projectID: "p", accessToken: "at")
            XCTFail("expected throw")
        } catch let error as AnonymousAuthError {
            XCTAssertEqual(error, .http(403, "PERMISSION_DENIED"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testTransportFailureThrowsNetwork() async {
        // A dropped connection (URLError) must surface as .network, not .http.
        StubURLProtocol.failure = { _ in URLError(.notConnectedToInternet) }
        do {
            try await enabler().enable(projectID: "p", accessToken: "at")
            XCTFail("expected throw")
        } catch let error as AnonymousAuthError {
            guard case .network = error else {
                return XCTFail("expected .network, got \(error)")
            }
        } catch { XCTFail("wrong error: \(error)") }
    }

    private final class CapturedRequest: @unchecked Sendable {
        var method: String?; var url: String?; var authorization: String?; var body: Data?
    }
}

// Test helper: StubURLProtocol strips httpBody into a stream; read it back.
extension URLRequest {
    func httpBodyData() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
