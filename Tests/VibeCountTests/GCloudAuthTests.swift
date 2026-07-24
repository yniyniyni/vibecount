import XCTest
@testable import VibeCount

final class GCloudAuthTests: XCTestCase {
    func testAuthorizeURLIncludesCloudScope() {
        let url = GoogleOAuth.authorizeURL(
            clientID: "cid", redirectURI: "http://127.0.0.1:1",
            challenge: "c", state: "s", scope: GCloudAuth.scopes)
        let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "scope" }!.value!
        XCTAssertTrue(scope.contains("cloud-platform"))
        XCTAssertTrue(scope.contains("openid"))
    }

    func testDefaultAuthorizeScopeUnchanged() {
        let url = GoogleOAuth.authorizeURL(
            clientID: "cid", redirectURI: "http://127.0.0.1:1", challenge: "c", state: "s")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "openid email profile")
        // Defaults must reproduce today's URL exactly — no offline-access params
        // leaking into the existing identity-linking flow.
        XCTAssertNil(items.first { $0.name == "access_type" })
        XCTAssertNil(items.first { $0.name == "prompt" })
    }

    func testOfflineAccessAddsConsentParams() {
        let url = GoogleOAuth.authorizeURL(
            clientID: "cid", redirectURI: "http://127.0.0.1:1", challenge: "c", state: "s",
            scope: GCloudAuth.scopes, offlineAccess: true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "access_type" }?.value, "offline")
        XCTAssertEqual(items.first { $0.name == "prompt" }?.value, "consent")
    }

    func testExchangeCodeForTokensParsesAllFields() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { _ in
            (200, try! JSONSerialization.data(withJSONObject: [
                "access_token": "at", "refresh_token": "rt", "expires_in": 3599,
            ]))
        }
        defer { StubURLProtocol.handler = nil }
        let tokens = try await GoogleOAuth.exchangeCodeForTokens(
            "code", clientID: "cid", clientSecret: "sec",
            redirectURI: "http://127.0.0.1:1", verifier: "v",
            session: URLSession(configuration: config))
        XCTAssertEqual(tokens, GoogleTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3599))
    }

    func testRefreshAccessTokenReturnsNewToken() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = { _ in
            (200, try! JSONSerialization.data(withJSONObject: ["access_token": "fresh"]))
        }
        defer { StubURLProtocol.handler = nil }
        let token = try await GoogleOAuth.refreshAccessToken(
            refreshToken: "rt", clientID: "cid", clientSecret: "sec",
            session: URLSession(configuration: config))
        XCTAssertEqual(token, "fresh")
    }
}
