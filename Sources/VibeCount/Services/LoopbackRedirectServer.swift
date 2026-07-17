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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let data, !data.isEmpty else { return }
            Task { await self?.handle(data: data, on: connection) }
        }
    }

    private func handle(data: Data, on connection: NWConnection) {
        // "GET /callback?code=x&state=y HTTP/1.1" — the request line is all
        // we need; headers and body are irrelevant for a redirect catch.
        let head = String(decoding: data, as: UTF8.self)
        let target = head.split(separator: "\r\n").first?.split(separator: " ")
            .dropFirst().first.map(String.init) ?? "/"
        let components = URLComponents(string: target)
        let request = Request(
            path: components?.path ?? "/",
            queryItems: components?.queryItems ?? [])

        let html = "<html><body style=\"font-family:-apple-system\"><h3>Signed in — you can close this tab and return to VibeCount.</h3></body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        guard !delivered else { return }
        delivered = true
        if let pending {
            self.pending = nil
            pending.resume(returning: request)
        } else {
            buffered = request
        }
    }
}
