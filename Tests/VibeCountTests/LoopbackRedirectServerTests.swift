// Tests/VibeCountTests/LoopbackRedirectServerTests.swift
import Network
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

    func testStrayRequestGets404AndDoesNotConsumeDelivery() async throws {
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        async let redirect = server.awaitRedirect(timeout: 5)
        try await Task.sleep(for: .milliseconds(50))

        // A request without code/error (favicon probe, port scan, stray local
        // process) must not consume the one-shot delivery.
        let stray = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        let (_, strayResponse) = try await URLSession.shared.data(from: stray)
        XCTAssertEqual((strayResponse as? HTTPURLResponse)?.statusCode, 404)

        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=c1&state=st")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let request = try await redirect
        var query: [String: String] = [:]
        for item in request.queryItems { query[item.name] = item.value }
        XCTAssertEqual(query["code"], "c1")
        await server.stop()
    }

    func testErrorRedirectIsDelivered() async throws {
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        async let redirect = server.awaitRedirect(timeout: 5)
        try await Task.sleep(for: .milliseconds(50))

        // A consent denial redirects with error= and no code — it must still
        // be delivered so the flow can end as cancelled instead of timing out.
        let url = URL(string: "http://127.0.0.1:\(port)/?error=access_denied&state=st")!
        _ = try await URLSession.shared.data(from: url)

        let request = try await redirect
        var query: [String: String] = [:]
        for item in request.queryItems { query[item.name] = item.value }
        XCTAssertEqual(query["error"], "access_denied")
        await server.stop()
    }

    func testRequestLineSplitAcrossSegmentsIsReassembled() async throws {
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        async let redirect = server.awaitRedirect(timeout: 5)
        try await Task.sleep(for: .milliseconds(50))

        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data("GET /callback?code=c2".utf8),
                        completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(100))
        connection.send(content: Data("&state=s2 HTTP/1.1\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in })

        let request = try await redirect
        XCTAssertEqual(request.path, "/callback")
        var query: [String: String] = [:]
        for item in request.queryItems { query[item.name] = item.value }
        XCTAssertEqual(query["code"], "c2")
        XCTAssertEqual(query["state"], "s2")
        connection.cancel()
        await server.stop()
    }

    func testWrongStateRedirectGets404AndDoesNotConsumeDelivery() async throws {
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        await server.expect(state: "good")
        async let redirect = server.awaitRedirect(timeout: 5)
        try await Task.sleep(for: .milliseconds(50))

        // A local process that doesn't know the nonce must not be able to
        // kill the sign-in with a fabricated error redirect.
        let attack = URL(string: "http://127.0.0.1:\(port)/?error=x&state=evil")!
        let (_, attackResponse) = try await URLSession.shared.data(from: attack)
        XCTAssertEqual((attackResponse as? HTTPURLResponse)?.statusCode, 404)

        let real = URL(string: "http://127.0.0.1:\(port)/callback?code=c1&state=good")!
        let (_, response) = try await URLSession.shared.data(from: real)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let request = try await redirect
        var query: [String: String] = [:]
        for item in request.queryItems { query[item.name] = item.value }
        XCTAssertEqual(query["code"], "c1")
        await server.stop()
    }

    func testErrorRedirectGetsNonSuccessPage() async throws {
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        async let redirect = server.awaitRedirect(timeout: 5)
        try await Task.sleep(for: .milliseconds(50))

        // Consent denial must not be answered with a "Signed in" page.
        let url = URL(string: "http://127.0.0.1:\(port)/?error=access_denied&state=st")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("not completed"))
        XCTAssertFalse(body.contains("Signed in"))
        _ = try await redirect
        await server.stop()
    }

    func testRedirectBeforeAwaitIsBuffered() async throws {
        // The browser can beat awaitRedirect to the port; the buffered
        // request must be delivered, not dropped.
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        let url = URL(string: "http://127.0.0.1:\(port)/?code=c9&state=st")!
        _ = try await URLSession.shared.data(from: url)

        let request = try await server.awaitRedirect(timeout: 5)
        var query: [String: String] = [:]
        for item in request.queryItems { query[item.name] = item.value }
        XCTAssertEqual(query["code"], "c9")
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
