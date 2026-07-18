import Foundation

enum JoinLinkError: Error, Equatable, LocalizedError {
    case notAJoinLink
    case unsupportedVersion
    case missingFields
    case malformedField

    var errorDescription: String? {
        switch self {
        case .notAJoinLink: "That doesn't look like a VibeCount join link."
        case .unsupportedVersion: "This join link needs a newer version of VibeCount."
        case .missingFields: "This join link is incomplete — ask the host to re-share it."
        case .malformedField: "This join link contains invalid characters — ask the host to re-share it."
        }
    }
}

/// The one wire format for joining a group, used identically as a clickable
/// deep link and as a pasted string:
///     vibecount://join?v=1&p=<projectID>&k=<apiKey>&c=<hostInviteCode>
struct JoinLink: Equatable {
    static let version = "1"

    let projectID: String
    let apiKey: String
    /// Normalized host invite code, or nil. A malformed `c` parameter is
    /// dropped rather than failing the parse — joining still works, the
    /// host just isn't auto-friended.
    let hostInviteCode: String?

    /// Host-owned Google OAuth client for optional sign-in. Both-or-nothing:
    /// a link carrying only one of gi/gs is treated as carrying neither.
    var googleClientID: String? = nil
    var googleClientSecret: String? = nil

    var url: URL {
        var components = URLComponents()
        components.scheme = "vibecount"
        components.host = "join"
        var items = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "p", value: projectID),
            URLQueryItem(name: "k", value: apiKey),
        ]
        if let hostInviteCode {
            items.append(URLQueryItem(name: "c", value: hostInviteCode))
        }
        if let googleClientID, let googleClientSecret {
            items.append(URLQueryItem(name: "gi", value: googleClientID))
            items.append(URLQueryItem(name: "gs", value: googleClientSecret))
        }
        components.queryItems = items
        return components.url!
    }

    static func parse(_ raw: String) -> Result<JoinLink, JoinLinkError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return .failure(.notAJoinLink)
        }
        return parse(url: url)
    }

    static func parse(url: URL) -> Result<JoinLink, JoinLinkError> {
        guard url.scheme?.lowercased() == "vibecount",
              url.host?.lowercased() == "join",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.notAJoinLink)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value
        }
        guard query["v"] == Self.version else { return .failure(.unsupportedVersion) }
        guard let projectID = query["p"], !projectID.isEmpty,
              let apiKey = query["k"], !apiKey.isEmpty else {
            return .failure(.missingFields)
        }
        // A join link is untrusted input. FirestoreClient interpolates the
        // project id and API key straight into REST URLs it builds with a
        // force-unwrapped `URL(string:)`, so any value carrying characters
        // outside the URL-unreserved set could crash that construction (or, at
        // best, produce a bogus path). Reject those here, at the boundary.
        guard Self.isURLSafe(projectID), Self.isURLSafe(apiKey) else {
            return .failure(.malformedField)
        }
        var link = JoinLink(
            projectID: projectID, apiKey: apiKey,
            hostInviteCode: query["c"].flatMap(InviteCode.normalize))
        if let gi = query["gi"], !gi.isEmpty,
           let gs = query["gs"], !gs.isEmpty {
            link.googleClientID = gi
            link.googleClientSecret = gs
        }
        return .success(link)
    }

    /// The RFC 3986 "unreserved" set — safe to sit anywhere in a URL's path or
    /// query without escaping, breaking parsing, or altering the host. Real
    /// Firebase project ids (`[a-z0-9-]`) and Web API keys (`AIza…`, alphanumeric
    /// plus `-_`) are always a subset.
    private static let urlUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func isURLSafe(_ value: String) -> Bool {
        CharacterSet(charactersIn: value).isSubset(of: urlUnreserved)
    }
}
