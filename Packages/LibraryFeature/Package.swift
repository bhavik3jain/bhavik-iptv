// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
let package = Package(
    name: "LibraryFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LibraryFeature", targets: ["LibraryFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
    ],
    targets: [
        .target(name: "LibraryFeature", dependencies: ["Core", "CatalogKit", "HouseholdKit"]),
    ]
)
