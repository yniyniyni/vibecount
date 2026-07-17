// Tests/VibeCountTests/GoogleOAuthTests.swift
import XCTest
@testable import VibeCount

final class GoogleOAuthTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testPKCEGeneratesValidVerifierAndChallenge() {
        let pkce = PKCE.generate()
        XCTAssertEqual(pkce.verifier.count, 64)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(pkce.verifier.allSatisfy(allowed.contains))
        // Challenge is base64url (no padding, no +/): 43 chars for SHA-256.
        XCTAssertEqual(pkce.challenge.count, 43)
        XCTAssertFalse(pkce.challenge.contains("="))
        XCTAssertFalse(pkce.challenge.contains("+"))
        XCTAssertFalse(pkce.challenge.contains("/"))
        XCTAssertNotEqual(PKCE.generate().verifier, pkce.verifier)
    }

    func testChallengeMatchesRFCTestVector() {
        // RFC 7636 appendix B: verifier → challenge.
        let challenge = PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeURLCarriesAllParams() throws {
        let url = GoogleOAuth.authorizeURL(
            clientID: "cid", redirectURI: "http://127.0.0.1:1234",
            challenge: "chal", state: "st")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        XCTAssertEqual(query["client_id"], "cid")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:1234")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["scope"], "openid email profile")
        XCTAssertEqual(query["code_challenge"], "chal")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "st")
    }

    func testParseRedirectExtractsCodeAndChecksState() {
        let good = GoogleOAuth.parseRedirect(
            queryItems: [.init(name: "code", value: "c1"), .init(name: "state", value: "st")],
            expectedState: "st")
        XCTAssertEqual(good, .success("c1"))
        let badState = GoogleOAuth.parseRedirect(
            queryItems: [.init(name: "code", value: "c1"), .init(name: "state", value: "evil")],
            expectedState: "st")
        XCTAssertEqual(badState, .failure(.cancelled))
        let denied = GoogleOAuth.parseRedirect(
            queryItems: [.init(name: "error", value: "access_denied"), .init(name: "state", value: "st")],
            expectedState: "st")
        XCTAssertEqual(denied, .failure(.cancelled))
    }

    func testExchangeCodePostsFormAndReturnsIDToken() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.absoluteString, "https://oauth2.googleapis.com/token")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = String(decoding: StubURLProtocol.body(of: request), as: UTF8.self)
            XCTAssertTrue(body.contains("grant_type=authorization_code"))
            XCTAssertTrue(body.contains("code=c1"))
            XCTAssertTrue(body.contains("client_id=cid"))
            XCTAssertTrue(body.contains("client_secret=sec"))
            XCTAssertTrue(body.contains("code_verifier=ver"))
            return (200, try! JSONSerialization.data(withJSONObject: ["id_token": "google-jwt", "access_token": "at"]))
        }
        let token = try await GoogleOAuth.exchangeCode(
            "c1", clientID: "cid", clientSecret: "sec",
            redirectURI: "http://127.0.0.1:1", verifier: "ver",
            session: Self.stubbedSession())
        XCTAssertEqual(token, "google-jwt")
    }

    func testExchangeCodeSurfacesServerError() async {
        StubURLProtocol.handler = { _ in
            (400, try! JSONSerialization.data(withJSONObject: ["error": "invalid_grant"]))
        }
        do {
            _ = try await GoogleOAuth.exchangeCode(
                "c1", clientID: "cid", clientSecret: "sec",
                redirectURI: "http://127.0.0.1:1", verifier: "ver",
                session: Self.stubbedSession())
            XCTFail("expected throw")
        } catch let error as GoogleSignInError {
            XCTAssertEqual(error, .server("invalid_grant"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
