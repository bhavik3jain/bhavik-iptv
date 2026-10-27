// swift-tools-version: 6.0
import PackageDescription

// The household shared through iCloud: profiles, sources (logins encrypted),
// favorites, progress, who's watching, roles. The only package that talks to
// CloudKit; never talks to a provider.
let package = Package(
    name: "HouseholdKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [.library(name: "HouseholdKit", targets: ["HouseholdKit"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "HouseholdKit", dependencies: ["Core"]),
        .testTarget(name: "HouseholdKitTests", dependencies: ["HouseholdKit"]),
    ]
)
