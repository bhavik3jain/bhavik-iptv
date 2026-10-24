// swift-tools-version: 6.0
import PackageDescription

// The per-device catalog: a local Core Data store, imports from SourceKit,
// stable item keys, search and stream-link resolution. Never synced, never
// touches iCloud, safe to delete.
let package = Package(
    name: "CatalogKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "CatalogKit", targets: ["CatalogKit"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../SourceKit"),
    ],
    targets: [
        .target(name: "CatalogKit", dependencies: ["Core", "SourceKit"]),
        .testTarget(name: "CatalogKitTests", dependencies: ["CatalogKit"]),
    ]
)
