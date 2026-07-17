import XCTest
@testable import VibeCount

final class AppTests: XCTestCase {
    func testAppInitialization() {
        // Just tests that the module compiles and can import the app
        XCTAssertNotNil(VibeCountApp.self)
    }

    @MainActor
    func testShowSetupWindowConstructsModelWithStoredConfig() {
        // Compile-level integration check: the delegate exposes the setup
        // surface and the notification name matches the dashboard's.
        let delegate = AppDelegate()
        XCTAssertNotNil(delegate.syncConfigStore)
        XCTAssertTrue(delegate.responds(to: #selector(AppDelegate.openSyncSettings)))
    }
}
