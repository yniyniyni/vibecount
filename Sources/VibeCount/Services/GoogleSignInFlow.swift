// Sources/VibeCount/Services/GoogleSignInFlow.swift
import AppKit
import Foundation

/// Orchestrates the installed-app OAuth dance: loopback listener → browser
/// consent → redirect catch → code-for-token exchange. Returns the Google
/// id_token; Firebase linking is the caller's next step (FirestoreClient).
struct GoogleSignInFlow {
    var openURL: @Sendable (URL) -> Void
    var session: URLSession
    var timeout: TimeInterval

    init(openURL: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) },
         session: URLSession = FirestoreClient.defaultSession(),
         timeout: TimeInterval = 120) {
        self.openURL = openURL
        self.session = session
        self.timeout = timeout
    }

    func signIn(clientID: String, clientSecret: String) async throws -> String {
        let server = LoopbackRedirectServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let redirectURI = "http://127.0.0.1:\(port)"
        let pkce = PKCE.generate()
        let state = UUID().uuidString
        await server.expect(state: state)
        openURL(GoogleOAuth.authorizeURL(
            clientID: clientID, redirectURI: redirectURI,
            challenge: pkce.challenge, state: state))

        let redirect = try await server.awaitRedirect(timeout: timeout)
        let code = try GoogleOAuth.parseRedirect(
            queryItems: redirect.queryItems, expectedState: state).get()
        return try await GoogleOAuth.exchangeCode(
            code, clientID: clientID, clientSecret: clientSecret,
            redirectURI: redirectURI, verifier: pkce.verifier, session: session)
    }
}
