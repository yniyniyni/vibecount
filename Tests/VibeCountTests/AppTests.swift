import XCTest
@testable import VibeCount

final class AppTests: XCTestCase {
    func testAppInitialization() {
        // Just tests that the module compiles and can import the app
        XCTAssertNotNil(VibeCountApp.self)
    }
}
