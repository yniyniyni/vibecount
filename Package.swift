// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeCount",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VibeCount", targets: ["VibeCount"])
    ],
    targets: [
        // GoogleService-Info.plist is intentionally NOT a SwiftPM resource: the
        // app reads it from Bundle.main, which only exists in the .app bundle
        // that scripts/build-app.sh assembles. The (gitignored) plist lives at
        // the repository root so a fresh clone builds without warnings.
        .executableTarget(name: "VibeCount"),
        .testTarget(name: "VibeCountTests", dependencies: ["VibeCount"])
    ]
)
