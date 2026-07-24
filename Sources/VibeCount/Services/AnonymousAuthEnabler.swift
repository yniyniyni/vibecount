import Foundation

/// Failure enabling the Anonymous auth provider.
enum AnonymousAuthError: Error, Equatable {
    case http(Int, String)
    case network(String)
}

/// Turns on Firebase Anonymous authentication via the Identity Toolkit Admin
/// API — the one setup step the firebase CLI cannot perform. Idempotent:
/// PATCHing enabled=true repeatedly is safe.
struct AnonymousAuthEnabler {
    let session: URLSession

    init(session: URLSession = FirestoreClient.defaultSession()) {
        self.session = session
    }

    func enable(projectID: String, accessToken: String) async throws {
        var components = URLComponents(
            string: "https://identitytoolkit.googleapis.com/admin/v2/projects/\(projectID)/config")!
        components.queryItems = [URLQueryItem(name: "updateMask", value: "signIn.anonymous.enabled")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["signIn": ["anonymous": ["enabled": true]]])
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
                throw AnonymousAuthError.http(status, message)
            }
        } catch let error as AnonymousAuthError {
            throw error
        } catch {
            throw AnonymousAuthError.network(error.localizedDescription)
        }
    }
}
