// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
let package = Package(
    name: "ProfilesFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ProfilesFeature", targets: ["ProfilesFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../HouseholdKit"),
    ],
    targets: [
        .target(name: "ProfilesFeature", dependencies: ["Core", "HouseholdKit"]),
    ]
)
