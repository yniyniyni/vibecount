import XCTest
@testable import VibeCount

final class JoinLinkTests: XCTestCase {
    func testEncodeParseRoundTrip() throws {
        let link = JoinLink(projectID: "my-proj-123", apiKey: "AIzaSyABC_def-123",
                            hostInviteCode: "ABCDEFGH23456789")
        let parsed = try JoinLink.parse(link.url.absoluteString).get()
        XCTAssertEqual(parsed, link)
    }

    func testEncodeWithoutInviteCode() throws {
        let link = JoinLink(projectID: "p", apiKey: "k", hostInviteCode: nil)
        XCTAssertFalse(link.url.absoluteString.contains("c="))
        XCTAssertEqual(try JoinLink.parse(link.url.absoluteString).get(), link)
    }

    func testParseToleratesSurroundingWhitespace() throws {
        let raw = "  \n vibecount://join?v=1&p=proj&k=key \t"
        let parsed = try JoinLink.parse(raw).get()
        XCTAssertEqual(parsed.projectID, "proj")
        XCTAssertEqual(parsed.apiKey, "key")
        XCTAssertNil(parsed.hostInviteCode)
    }

    func testParseNormalizesInviteCode() throws {
        let raw = "vibecount://join?v=1&p=proj&k=key&c=abcd-efgh-2345-6789"
        XCTAssertEqual(try JoinLink.parse(raw).get().hostInviteCode, "ABCDEFGH23456789")
    }

    func testParseDropsInvalidInviteCodeInsteadOfFailing() throws {
        let raw = "vibecount://join?v=1&p=proj&k=key&c=tooshort"
        XCTAssertNil(try JoinLink.parse(raw).get().hostInviteCode)
    }

    func testRejectsWrongScheme() {
        XCTAssertEqual(JoinLink.parse("https://join?v=1&p=p&k=k"), .failure(.notAJoinLink))
        XCTAssertEqual(JoinLink.parse("total garbage"), .failure(.notAJoinLink))
        XCTAssertEqual(JoinLink.parse("vibecount://other?v=1&p=p&k=k"), .failure(.notAJoinLink))
    }

    func testRejectsUnknownOrMissingVersion() {
        XCTAssertEqual(JoinLink.parse("vibecount://join?v=2&p=p&k=k"), .failure(.unsupportedVersion))
        XCTAssertEqual(JoinLink.parse("vibecount://join?p=p&k=k"), .failure(.unsupportedVersion))
    }

    func testRejectsMissingOrEmptyFields() {
        XCTAssertEqual(JoinLink.parse("vibecount://join?v=1&p=p"), .failure(.missingFields))
        XCTAssertEqual(JoinLink.parse("vibecount://join?v=1&k=k"), .failure(.missingFields))
        XCTAssertEqual(JoinLink.parse("vibecount://join?v=1&p=&k=k"), .failure(.missingFields))
    }

    func testRejectsMalformedProjectOrKey() {
        // A slash would smuggle extra path (or a different resource) into the
        // Firestore REST URL; a space breaks URL(string:) outright. Both must
        // be rejected at the parse boundary rather than crashing later.
        XCTAssertEqual(
            JoinLink.parse("vibecount://join?v=1&p=proj/evil&k=key"), .failure(.malformedField))
        XCTAssertEqual(
            JoinLink.parse("vibecount://join?v=1&p=proj&k=a%20b"), .failure(.malformedField))
    }

    func testAcceptsRealisticProjectAndKey() throws {
        // Real Firebase ids/keys use only unreserved characters and must pass.
        let parsed = try JoinLink.parse(
            "vibecount://join?v=1&p=vibe-count-app-0703&k=AIzaSyDt9_eZ-Esz").get()
        XCTAssertEqual(parsed.projectID, "vibe-count-app-0703")
        XCTAssertEqual(parsed.apiKey, "AIzaSyDt9_eZ-Esz")
    }

    func testGoogleParamsRoundTrip() throws {
        var link = JoinLink(projectID: "p", apiKey: "k", hostInviteCode: nil)
        link.googleClientID = "cid.apps.googleusercontent.com"
        link.googleClientSecret = "GOCSPX-abc"
        let parsed = try JoinLink.parse(link.url.absoluteString).get()
        XCTAssertEqual(parsed, link)
    }

    func testGoogleParamsOmittedWhenAbsent() throws {
        let link = JoinLink(projectID: "p", apiKey: "k", hostInviteCode: nil)
        XCTAssertFalse(link.url.absoluteString.contains("gi="))
        XCTAssertFalse(link.url.absoluteString.contains("gs="))
    }

    func testGoogleParamsAreBothOrNothing() throws {
        let onlyID = try JoinLink.parse("vibecount://join?v=1&p=p&k=k&gi=cid").get()
        XCTAssertNil(onlyID.googleClientID)
        XCTAssertNil(onlyID.googleClientSecret)
        let emptySecret = try JoinLink.parse("vibecount://join?v=1&p=p&k=k&gi=cid&gs=").get()
        XCTAssertNil(emptySecret.googleClientID)
    }

    func testOldLinksStillParse() throws {
        let parsed = try JoinLink.parse("vibecount://join?v=1&p=p&k=k&c=ABCD-EFGH-2345-6789").get()
        XCTAssertNil(parsed.googleClientID)
        XCTAssertEqual(parsed.projectID, "p")
    }
}
