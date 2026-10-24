// swift-tools-version: 6.0
import PackageDescription

// The player: one PlaybackEngine protocol over AVPlayer (HLS, MP4) and VLCKit
// (raw MPEG-TS, MKV, everything else), the engine choice, picture in picture,
// Now Playing and the player screen. VLCKit is the app's only remote
// dependency and only this package imports it.
let package = Package(
    name: "PlayerKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlayerKit", targets: ["PlayerKit"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "PlayerKit", dependencies: ["Core"]),
        .testTarget(name: "PlayerKitTests", dependencies: ["PlayerKit"]),
    ]
)
