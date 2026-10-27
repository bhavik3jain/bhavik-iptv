// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
// SourceKit is here for the stream link's format hint, which multi-view maps
// to PlayerKit's StreamFormat when it builds a tile's PlayerItem.
let package = Package(
    name: "LiveTVFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LiveTVFeature", targets: ["LiveTVFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../SourceKit"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
        .package(path: "../PlayerKit"),
    ],
    targets: [
        .target(name: "LiveTVFeature", dependencies: ["Core", "SourceKit", "CatalogKit", "HouseholdKit", "PlayerKit"]),
        .testTarget(name: "LiveTVFeatureTests", dependencies: ["LiveTVFeature", "Core", "SourceKit", "CatalogKit", "PlayerKit"]),
    ]
)
