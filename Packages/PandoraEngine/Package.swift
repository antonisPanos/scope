// swift-tools-version: 6.0
import PackageDescription

// The engine targets an older macOS than the app so its tests can run on
// GitHub's hosted runners, which lag behind the macOS version Pandora ships for.
let package = Package(
    name: "PandoraEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PandoraEngine", targets: ["PandoraEngine"]),
    ],
    targets: [
        .target(
            name: "PandoraEngine",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PandoraEngineTests",
            dependencies: ["PandoraEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
