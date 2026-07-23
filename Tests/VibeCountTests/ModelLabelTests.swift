import XCTest
@testable import VibeCount

final class ModelLabelTests: XCTestCase {
    func testClaudeFamiliesMapToShortLabels() {
        XCTAssertEqual(ModelLabel.from("claude-opus-4-20250514"), "Opus")
        XCTAssertEqual(ModelLabel.from("claude-sonnet-4-5-20250929"), "Sonnet")
        XCTAssertEqual(ModelLabel.from("claude-haiku-4-5-20251001"), "Haiku")
        XCTAssertEqual(ModelLabel.from("claude-fable-5"), "Fable")
    }

    func testGpt56VariantsGetFriendlyLabels() {
        XCTAssertEqual(ModelLabel.from("gpt-5.6-sol"), "GPT 5.6 Sol")
        XCTAssertEqual(ModelLabel.from("gpt-5.6-terra"), "GPT 5.6 Terra")
        XCTAssertEqual(ModelLabel.from("gpt-5.6-luna"), "GPT 5.6 Luna")
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
