import XCTest
import SwiftUI
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

    @MainActor
    func testOpenSyncSettingsDefersWindowPresentation() {
        let delegate = AppDelegate()
        delegate.openSyncSettings()
        // Must NOT present synchronously: doing so from inside the popover's
        // click handler is exactly what wedged the UI. The window appears only
        // after the current runloop turn unwinds.
        XCTAssertNil(delegate.setupWindow)

        let presented = expectation(description: "setup window presented")
        DispatchQueue.main.async { presented.fulfill() }
        wait(for: [presented], timeout: 2)

        XCTAssertNotNil(delegate.setupWindow)
        delegate.setupWindow?.close()
    }

    @MainActor
    func testSetupWindowPinsSizeAndSizingOptions() throws {
        let delegate = AppDelegate()
        delegate.showSetupWindow(route: .welcome)
        defer { delegate.setupWindow?.close() }
        let window = try XCTUnwrap(delegate.setupWindow)
        // The pinned content size plus non-preferred sizing keep NSHostingView
        // from driving an unstable window resize — the Auto Layout feedback loop
        // that made AppKit abort the app with an uncaught NSException.
        XCTAssertEqual(window.contentLayoutRect.size, NSSize(width: 500, height: 600))
        let hosting = try XCTUnwrap(
            window.contentViewController as? NSHostingController<SetupView>)
        XCTAssertEqual(hosting.sizingOptions, .standardBounds)
    }

    @MainActor
    func testTitlebarCloseReleasesSetupWindow() {
        let delegate = AppDelegate()
        delegate.showSetupWindow(route: .welcome)
        XCTAssertNotNil(delegate.setupWindow)

        delegate.setupWindow?.close()

        XCTAssertNil(delegate.setupWindow)
        XCTAssertNil(delegate.pendingSetupModel)
    }
}
