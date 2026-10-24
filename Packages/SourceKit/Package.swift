// swift-tools-version: 6.0
import PackageDescription

// The provider clients: Stalker portal, Xtream Codes, M3U + XMLTV, behind one
// SourceClient protocol. Depends on nothing, never touches iCloud.
let package = Package(
    name: "SourceKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "SourceKit", targets: ["SourceKit"])],
    targets: [
        .target(name: "SourceKit"),
        .testTarget(name: "SourceKitTests", dependencies: ["SourceKit"], resources: [.copy("Fixtures")]),
    ]
)
