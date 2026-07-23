import XCTest
@testable import VibeCount

final class ModelLabelTests: XCTestCase {
    func testClaudeFamiliesMapToShortLabels() {
        XCTAssertEqual(ModelLabel.from("claude-opus-4-20250514"), "Opus")
        XCTAssertEqual(ModelLabel.from("claude-sonnet-4-5-20250929"), "Sonnet")
        XCTAssertEqual(ModelLabel.from("claude-haiku-4-5-20251001"), "Haiku")
    }

    func testUnknownIdPassesThroughUnchanged() {
        XCTAssertEqual(ModelLabel.from("gpt-5-codex"), "gpt-5-codex")
        XCTAssertEqual(ModelLabel.from("some-future-model"), "some-future-model")
    }

    func testNilOrEmptyIsUnknown() {
        XCTAssertEqual(ModelLabel.from(nil), "Unknown")
        XCTAssertEqual(ModelLabel.from(""), "Unknown")
        XCTAssertEqual(ModelLabel.from("   "), "Unknown")
    }
}
