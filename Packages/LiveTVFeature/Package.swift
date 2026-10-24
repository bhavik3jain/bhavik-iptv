// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
let package = Package(
    name: "LiveTVFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LiveTVFeature", targets: ["LiveTVFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
        .package(path: "../PlayerKit"),
    ],
    targets: [
        .target(name: "LiveTVFeature", dependencies: ["Core", "CatalogKit", "HouseholdKit", "PlayerKit"]),
    ]
)
