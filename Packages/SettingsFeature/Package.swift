// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
// SourceKit is here only to name `SourceConfiguration` (the catalog's sources
// for "Refresh everything now"). PlayerKit is deliberately not: depending on
// it would pull VLCKit's ~900 MB binary into this package's builds for one
// version string, so Acknowledgements carries the pinned version itself (see
// `Acknowledgements.vlcKitVersion`).
let package = Package(
    name: "SettingsFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [.library(name: "SettingsFeature", targets: ["SettingsFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../SourceKit"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
    ],
    targets: [
        .target(
            name: "SettingsFeature",
            dependencies: ["Core", "SourceKit", "CatalogKit", "HouseholdKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "SettingsFeatureTests", dependencies: ["SettingsFeature", "HouseholdKit"]),
    ]
)
