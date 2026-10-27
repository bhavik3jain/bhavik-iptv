// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
// The string catalog under Resources gives the target a `Bundle.module`, so
// every user-visible string here is looked up in this package's own table.
let package = Package(
    name: "SearchFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "SearchFeature", targets: ["SearchFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
    ],
    targets: [
        .target(
            name: "SearchFeature",
            dependencies: ["Core", "CatalogKit", "HouseholdKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "SearchFeatureTests", dependencies: ["SearchFeature", "Core", "CatalogKit"]),
    ]
)
