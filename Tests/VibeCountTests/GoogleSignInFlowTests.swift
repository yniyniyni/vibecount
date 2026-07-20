// Tests/VibeCountTests/GoogleSignInFlowTests.swift
import XCTest
@testable import VibeCount

final class GoogleSignInFlowTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Full flow with a fake browser: the openURL hook plays Google's role by
    /// echoing code+state back to the loopback listener, and the stubbed
    /// session answers the token exchange.
    func testEndToEndFlowReturnsIDToken() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url!.absoluteString, "https://oauth2.googleapis.com/token")
            return (200, try! JSONSerialization.data(withJSONObject: ["id_token": "the-jwt"]))
        }
        let flow = GoogleSignInFlow(
            openURL: { authorizeURL in
                // Simulate the user approving consent: Google redirects the
                // browser to our loopback redirect_uri with code + state.
                let components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
                var query: [String: String] = [:]
                for item in components.queryItems ?? [] { query[item.name] = item.value }
                let redirect = URL(string: "\(query["redirect_uri"]!)/?code=auth-code&state=\(query["state"]!)")!
                Task { _ = try? await URLSession.shared.data(from: redirect) }
            },
            session: Self.stubbedSession(),
            timeout: 5)
        let token = try await flow.signIn(clientID: "cid", clientSecret: "sec")
        XCTAssertEqual(token, "the-jwt")
    }

    func testTimeoutThrowsCancelled() async {
        let flow = GoogleSignInFlow(openURL: { _ in }, session: Self.stubbedSession(), timeout: 0.3)
        do {
            _ = try await flow.signIn(clientID: "cid", clientSecret: "sec")
            XCTFail("expected timeout")
        } catch let error as GoogleSignInError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStateMismatchThrowsCancelled() async {
        let flow = GoogleSignInFlow(
            openURL: { authorizeURL in
                let components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
                var query: [String: String] = [:]
                for item in components.queryItems ?? [] { query[item.name] = item.value }
                let redirect = URL(string: "\(query["redirect_uri"]!)/?code=auth-code&state=WRONG")!
                Task { _ = try? await URLSession.shared.data(from: redirect) }
            },
            session: Self.stubbedSession(),
            timeout: 1)
        do {
            _ = try await flow.signIn(clientID: "cid", clientSecret: "sec")
            XCTFail("expected cancelled")
        } catch let error as GoogleSignInError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
