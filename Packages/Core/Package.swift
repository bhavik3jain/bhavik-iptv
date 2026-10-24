// swift-tools-version: 6.0
import PackageDescription

// Core depends on nothing. Shared chrome (theme, fonts, components), the Mac
// shims, formatting, and the app-wide routes and play intent that let feature
// packages ask for navigation and playback without importing each other.
let package = Package(
    name: "Core",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core", resources: [.process("Resources")]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
