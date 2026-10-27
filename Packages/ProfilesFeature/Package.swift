// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
// CatalogKit is here for the profile editor's category pickers (PRF-4, PRF-6).
// The string catalog under Resources gives the package its own `Bundle.module`,
// so its strings are looked up (and extracted by Xcode) in this package.
let package = Package(
    name: "ProfilesFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [.library(name: "ProfilesFeature", targets: ["ProfilesFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
    ],
    targets: [
        .target(
            name: "ProfilesFeature",
            dependencies: ["Core", "CatalogKit", "HouseholdKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ProfilesFeatureTests", dependencies: ["ProfilesFeature", "Core", "CatalogKit", "HouseholdKit"]),
    ]
)
