import XCTest
import SwiftUI
@testable import VibeCount

@MainActor
final class SetupViewTests: XCTestCase {
    private func model(route: SetupModel.Route) -> SetupModel {
        SetupModel(route: route, currentConfig: nil, ownInviteCode: nil,
                   actions: SetupActions(
                       validate: { _, _ in .success("uid") },
                       commit: { _, _ in },
                       fetchOwnInviteCode: { nil },
                       signInWithGoogle: { nil },
                       dismiss: {},
                       makeAutoHostSetup: { Self.makeStubAutoHostSetup() }))
    }

    private static func makeStubAutoHostSetup() -> AutoHostSetup {
        AutoHostSetup(dependencies: AutoSetupDependencies(
            locateCLI: { nil }, makeCLI: { _, _ in fatalError() },
            signIn: { GoogleTokens(accessToken: "", refreshToken: "", expiresIn: 0) },
            accessToken: { _ in "" }, enableAnonymous: { _, _ in },
            rulesPath: { nil }, commit: { _ in .success(()) }, newProjectID: { "p" }))
    }

    func testConstructsForEveryRoute() {
        for route in [SetupModel.Route.welcome, .host, .join, .settings] {
            XCTAssertNotNil(SetupView(model: model(route: route)).body)
        }
    }

    func testEveryRouteHasFixedFittingSize() {
        // A constant fitting size across routes is what prevents the window-size
        // feedback loop that trapped the app (SIGTRAP via _crashOnException).
        for route in [SetupModel.Route.welcome, .host, .join, .settings] {
            let hosting = NSHostingView(rootView: SetupView(model: model(route: route)))
            XCTAssertEqual(
                hosting.fittingSize, NSSize(width: 500, height: 600),
                "route \(route) should report a fixed fitting size")
        }
    }

    func testConsoleURLWithAndWithoutProject() {
        XCTAssertEqual(
            ConsoleURL.url("firestore", projectID: "my-proj").absoluteString,
            "https://console.firebase.google.com/project/my-proj/firestore")
        // "_" makes the console prompt for a project when none is typed yet.
        XCTAssertEqual(
            ConsoleURL.url("authentication/providers", projectID: "  ").absoluteString,
            "https://console.firebase.google.com/project/_/authentication/providers")
    }

    func testConstructsWithGoogleConfiguredModel() {
        var config = SyncConfig(projectID: "p", apiKey: "k", hostInviteCode: nil)
        config.googleClientID = "cid"
        config.googleClientSecret = "sec"
        let model = SetupModel(
            route: .settings, currentConfig: config, ownInviteCode: nil,
            linkedEmail: "a@b.c",
            actions: SetupActions(
                validate: { _, _ in .success("uid") },
                commit: { _, _ in },
                fetchOwnInviteCode: { nil },
                signInWithGoogle: { nil },
                dismiss: {},
                makeAutoHostSetup: { Self.makeStubAutoHostSetup() }))
        XCTAssertNotNil(SetupView(model: model).body)
    }

    func testHostDefaultsToAutomaticMode() {
        let model = model(route: .host)
        XCTAssertEqual(model.hostMode, .automatic)
    }

    func testSwitchingToManualPreservesRoute() {
        let model = model(route: .host)
        model.hostMode = .manual
        XCTAssertEqual(model.route, .host)
        XCTAssertEqual(model.hostMode, .manual)
    }
}
