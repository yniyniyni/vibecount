// Tests/VibeCountTests/LoopbackRedirectServerTests.swift
import XCTest
@testable import VibeCount

final class LoopbackRedirectServerTests: XCTestCase {
    func testDeliversFirstRequestAndResponds() async throws {
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        XCTAssertGreaterThan(port, 0)

        async let redirect = server.awaitRedirect(timeout: 5)
        // Tiny grace period so awaitRedirect is listening before the request.
        try await Task.sleep(for: .milliseconds(50))
        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=c1&state=st")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("close this tab"))

        let request = try await redirect
        XCTAssertEqual(request.path, "/callback")
        var query: [String: String] = [:]
        for item in request.queryItems { query[item.name] = item.value }
        XCTAssertEqual(query["code"], "c1")
        XCTAssertEqual(query["state"], "st")
        await server.stop()
    }

    func testTimesOutQuietly() async throws {
        let server = LoopbackRedirectServer()
        _ = try await server.start()
        do {
            _ = try await server.awaitRedirect(timeout: 0.3)
            XCTFail("expected timeout")
        } catch let error as GoogleSignInError {
            XCTAssertEqual(error, .cancelled)
        }
        await server.stop()
    }
}
