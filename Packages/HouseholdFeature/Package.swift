// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
let package = Package(
    name: "HouseholdFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "HouseholdFeature", targets: ["HouseholdFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../SourceKit"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
    ],
    targets: [
        .target(name: "HouseholdFeature", dependencies: ["Core", "SourceKit", "CatalogKit", "HouseholdKit"]),
    ]
)
