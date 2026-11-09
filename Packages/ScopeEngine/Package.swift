// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Positive selection: bounded builds do not even compile the volume suites.
let boundedProfile = ProcessInfo.processInfo.environment["SCOPE_TEST_PROFILE"] == "bounded"

// The engine targets an older macOS than the app so its tests can run on
// GitHub's hosted runners, which lag behind the macOS version Scope ships for.
let package = Package(
    name: "ScopeEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScopeEngine", targets: ["ScopeEngine"])
    ],
    targets: [
        // Declarations for the libarchive that ships with macOS.
        .target(
            name: "CArchive",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        .target(
            name: "ScopeEngine",
            dependencies: ["CArchive"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ] + [
        .testTarget(
            name: boundedProfile ? "ScopeBoundedTests" : "ScopeEngineTests",
            dependencies: ["ScopeEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
