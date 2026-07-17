// Sources/VibeCount/Utilities/InviteCode.swift
import Foundation

/// High-entropy invite codes: 16 characters from the Crockford base32 alphabet
/// (no I, L, O, U), ≈80 bits of entropy. Unlike the legacy 8-character UUID
/// prefix that doubled as the user id, a code grants nothing beyond "may read
/// this one user's usage row" — and only when presented at friend-add time.
enum InviteCode {
    static let length = 16
    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// A fresh random code from the system CSPRNG.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Canonical form of user input: separators stripped, uppercased. Returns
    /// nil when the result is not a well-formed code (wrong length or alphabet),
    /// which includes every legacy 8-character code.
    static func normalize(_ raw: String) -> String? {
        let separators = Set("- \t\n")
        let cleaned = String(raw.uppercased().filter { !separators.contains($0) })
        guard cleaned.count == length, cleaned.allSatisfy({ alphabet.contains($0) }) else {
            return nil
        }
        return cleaned
    }

    /// Groups a code for display: ABCD-EFGH-2345-6789.
    static func display(_ code: String) -> String {
        guard code.count > 4 else { return code }
        var groups: [String] = []
        var rest = Substring(code)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: "-")
    }
}
