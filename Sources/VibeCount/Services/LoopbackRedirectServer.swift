// Sources/VibeCount/Services/LoopbackRedirectServer.swift
import Foundation
import Network

/// One-shot loopback HTTP listener for the OAuth redirect. Binds 127.0.0.1
/// only; serves exactly one request, answers with a static "close this tab"
/// page, and shuts down. No TLS — the loopback interface never leaves the
/// machine, which is exactly the installed-app flow Google prescribes.
actor LoopbackRedirectServer {
    struct Request: Equatable, Sendable {
        let path: String
        let queryItems: [URLQueryItem]
    }

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var pending: CheckedContinuation<Request, Error>?
    /// A redirect that lands before awaitRedirect registers its continuation
    /// is buffered, not dropped — the browser can be faster than the caller.
    private var buffered: Request?
    private var delivered = false
    private var expectedState: String?

    /// Registers the state nonce the flow put in the authorize URL. Once set,
    /// only a redirect echoing this exact value may consume the one-shot
    /// delivery, so a local process that doesn't know the nonce can neither
    /// hijack nor kill the sign-in. Call between start() and opening the
    /// browser, so the gate is up before any redirect can arrive.
    func expect(state: String) {
        expectedState = state
    }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: GoogleSignInError.server(error.localizedDescription))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func awaitRedirect(timeout: TimeInterval) async throws -> Request {
        if let buffered {
            self.buffered = nil
            return buffered
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.timeOut()
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            // Entering the continuation is a suspension point, so a redirect
            // can land between the check above and here; deliver it now
            // instead of parking it in `buffered` past the timeout.
            if let buffered {
                self.buffered = nil
                continuation.resume(returning: buffered)
                return
            }
            pending = continuation
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        buffered = nil
        pending?.resume(throwing: GoogleSignInError.cancelled)
        pending = nil
    }

    private func timeOut() {
        guard pending != nil else { return }
        stop()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        read(from: connection, accumulated: Data())
    }

    /// Reads until the request line is complete (CRLF seen). Loopback requests
    /// almost always arrive in one segment, but a request line split across
    /// segments must be reassembled — a partial read would otherwise parse as
    /// an empty path and could consume the one-shot delivery.
    private func read(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let data, !data.isEmpty else { return }
            Task { await self?.consume(chunk: data, accumulated: accumulated, on: connection) }
        }
    }

    private func consume(chunk: Data, accumulated: Data, on connection: NWConnection) {
        var buffer = accumulated
        buffer.append(chunk)
        guard buffer.range(of: Data("\r\n".utf8)) != nil else {
            if buffer.count < 16 * 1024 {
                read(from: connection, accumulated: buffer)
            } else {
                connection.cancel()
            }
            return
        }
        handle(head: String(decoding: buffer, as: UTF8.self), on: connection)
    }

    private func handle(head: String, on connection: NWConnection) {
        // "GET /callback?code=x&state=y HTTP/1.1" — the request line is all
        // we need; headers and body are irrelevant for a redirect catch.
        let target = head.split(separator: "\r\n").first?.split(separator: " ")
            .dropFirst().first.map(String.init) ?? "/"
        let components = URLComponents(string: target)
        let request = Request(
            path: components?.path ?? "/",
            queryItems: components?.queryItems ?? [])

        // Only a plausible OAuth redirect (carrying a code or an error) may
        // consume the one-shot delivery — and once the flow has registered
        // its state nonce, the redirect must echo it. OAuth echoes state on
        // success and error redirects alike, so real redirects always pass;
        // anything else poking the port (a favicon fetch, a port scanner, a
        // stray local process) gets a 404 and the listener keeps waiting.
        var query: [String: String] = [:]
        for item in request.queryItems where query[item.name] == nil {
            query[item.name] = item.value
        }
        let plausible = query["code"] != nil || query["error"] != nil
        let stateMatches = expectedState == nil || query["state"] == expectedState
        guard plausible, stateMatches else {
            respond(status: "404 Not Found", body: "", on: connection)
            return
        }

        // An error redirect (consent denied) must not claim success.
        let heading = query["code"] != nil
            ? "Signed in — you can close this tab and return to VibeCount."
            : "Sign-in was not completed — you can close this tab and return to VibeCount."
        let html = "<html><body style=\"font-family:-apple-system\"><h3>\(heading)</h3></body></html>"
        respond(status: "200 OK", body: html, on: connection)

        guard !delivered else { return }
        delivered = true
        if let pending {
            self.pending = nil
            pending.resume(returning: request)
        } else {
            buffered = request
        }
    }

    private func respond(status: String, body: String, on connection: NWConnection) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
