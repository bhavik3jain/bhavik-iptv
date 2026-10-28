// swift-tools-version: 6.0
import PackageDescription

// A feature package: Core plus the kits it needs, never another feature.
// SourceKit is listed for `ContentKind` (category queries), which CatalogKit's
// API uses but does not re-export. Strings live in the package's own catalog
// (`bundle: .module`), as in Core and the other features: Xcode extracts a
// package's strings into its catalog, never into the app's.
let package = Package(
    name: "LibraryFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [.library(name: "LibraryFeature", targets: ["LibraryFeature"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../SourceKit"),
        .package(path: "../CatalogKit"),
        .package(path: "../HouseholdKit"),
        .package(path: "../DownloadKit"),
    ],
    targets: [
        .target(
            name: "LibraryFeature",
            dependencies: ["Core", "SourceKit", "CatalogKit", "HouseholdKit", "DownloadKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "LibraryFeatureTests", dependencies: ["LibraryFeature", "Core", "SourceKit", "CatalogKit", "HouseholdKit", "DownloadKit"]),
    ]
)
