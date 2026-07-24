import Foundation

/// One field value in Firestore's REST (typed JSON) encoding. Only the types
/// the VibeCount schema uses are supported; anything else decodes to nil and
/// is skipped by `FirestoreDocument`.
enum FirestoreValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case timestamp(Date)

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The `{"stringValue": …}` JSON object form used in request bodies.
    var json: [String: Any] {
        switch self {
        case .string(let string): ["stringValue": string]
        // Firestore's REST encoding carries int64 as a JSON string.
        case .integer(let int): ["integerValue": String(int)]
        case .double(let double): ["doubleValue": double]
        case .timestamp(let date): ["timestampValue": Self.iso8601Fractional.string(from: date)]
        }
    }

    init?(json: [String: Any]) {
        if let string = json["stringValue"] as? String {
            self = .string(string)
        } else if let raw = json["integerValue"] {
            if let string = raw as? String, let int = Int(string) {
                self = .integer(int)
            } else if let number = raw as? NSNumber {
                self = .integer(number.intValue)
            } else {
                return nil
            }
        } else if let raw = json["doubleValue"] {
            // Firestore sends floating-point values as bare JSON numbers.
            if let number = raw as? NSNumber {
                self = .double(number.doubleValue)
            } else {
                return nil
            }
        } else if let raw = json["timestampValue"] as? String,
                  let date = Self.iso8601Fractional.date(from: raw) ?? Self.iso8601Plain.date(from: raw) {
            self = .timestamp(date)
        } else {
            return nil
        }
    }

    var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var integerValue: Int? {
        if case .integer(let int) = self { int } else { nil }
    }

    var doubleValue: Double? {
        if case .double(let double) = self { double } else { nil }
    }
}

/// A Firestore document as returned by the REST API.
struct FirestoreDocument: Equatable, Sendable {
    /// Full resource name, e.g. projects/p/databases/(default)/documents/users/abc.
    let name: String
    let fields: [String: FirestoreValue]

    var documentID: String { String(name.split(separator: "/").last ?? "") }

    init(name: String, fields: [String: FirestoreValue]) {
        self.name = name
        self.fields = fields
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        self.name = name
        let raw = json["fields"] as? [String: [String: Any]] ?? [:]
        self.fields = raw.compactMapValues(FirestoreValue.init(json:))
    }

    /// Request-body form: `{"fields": {"a": {"stringValue": …}}}`.
    static func encodeFields(_ fields: [String: FirestoreValue]) -> [String: Any] {
        ["fields": fields.mapValues(\.json)]
    }
}
