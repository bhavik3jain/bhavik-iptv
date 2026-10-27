// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
// PlayerKit is here only for its public AirPlay route button in Home's
// header (mockup 02); playback itself goes through Core's `\.play`.
let package = Package(
    name: "HomeFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "HomeFeature", targets: ["HomeFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
        .package(path: "../PlayerKit"),
    ],
    targets: [
        .target(
            name: "HomeFeature",
            dependencies: ["Core", "CatalogKit", "HouseholdKit", "PlayerKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "HomeFeatureTests", dependencies: ["HomeFeature", "Core", "CatalogKit", "HouseholdKit"]),
    ]
)
