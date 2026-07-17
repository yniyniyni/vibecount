import XCTest
@testable import VibeCount

final class FirestoreValueTests: XCTestCase {
    func testStringRoundTrip() {
        let value = FirestoreValue.string("Ilya")
        XCTAssertEqual(value.json["stringValue"] as? String, "Ilya")
        XCTAssertEqual(FirestoreValue(json: value.json), value)
    }

    func testIntegerEncodesAsStringAndDecodesBothForms() {
        // Firestore's REST encoding sends int64 as a JSON *string*.
        let value = FirestoreValue.integer(42)
        XCTAssertEqual(value.json["integerValue"] as? String, "42")
        XCTAssertEqual(FirestoreValue(json: ["integerValue": "42"]), .integer(42))
        XCTAssertEqual(FirestoreValue(json: ["integerValue": 42]), .integer(42))
    }

    func testTimestampRoundTripAndNonFractionalDecode() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let json = FirestoreValue.timestamp(date).json
        guard case .timestamp(let decoded)? = FirestoreValue(json: json) else {
            return XCTFail("did not decode as timestamp")
        }
        XCTAssertEqual(decoded.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        // Server may omit fractional seconds.
        XCTAssertEqual(
            FirestoreValue(json: ["timestampValue": "2027-01-15T08:00:00Z"]).map { v -> Bool in
                if case .timestamp = v { true } else { false }
            },
            true
        )
    }

    func testUnknownValueDecodesToNil() {
        XCTAssertNil(FirestoreValue(json: ["booleanValue": true]))
        XCTAssertNil(FirestoreValue(json: [:]))
    }

    func testDocumentParsingAndID() {
        let json: [String: Any] = [
            "name": "projects/p/databases/(default)/documents/users/abc123",
            "fields": [
                "displayName": ["stringValue": "Bogdan"],
                "latestDailyTokens": ["integerValue": "7"],
                "unknownFutureField": ["booleanValue": true],  // skipped, not fatal
            ],
        ]
        let doc = FirestoreDocument(json: json)
        XCTAssertEqual(doc?.documentID, "abc123")
        XCTAssertEqual(doc?.fields["displayName"], .string("Bogdan"))
        XCTAssertEqual(doc?.fields["latestDailyTokens"], .integer(7))
        XCTAssertNil(doc?.fields["unknownFutureField"])
        XCTAssertNil(FirestoreDocument(json: ["fields": [:]]), "missing name is malformed")
    }

    func testEncodeFields() {
        let encoded = FirestoreDocument.encodeFields(["a": .string("x")])
        let fields = encoded["fields"] as? [String: [String: Any]]
        XCTAssertEqual(fields?["a"]?["stringValue"] as? String, "x")
    }
}
