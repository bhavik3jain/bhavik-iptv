// swift-tools-version: 6.0
import PackageDescription

// The player: one PlaybackEngine protocol over AVPlayer (HLS, MP4) and VLCKit
// (raw MPEG-TS, MKV, everything else), the engine choice, picture in picture,
// Now Playing and the player screen. VLCKit is the app's only remote
// dependency and only this package imports it.
//
// VLCKit comes from VideoLAN's own repository: since VLCKit 4 it ships a
// Package.swift whose binary target is one VLCKit.xcframework (a dynamic
// framework, so the LGPL's relinking duty is met by the framework itself) with
// slices for iOS devices, the iOS Simulator (arm64 + x86_64), tvOS devices,
// the tvOS Simulator (arm64 + x86_64) and macOS (arm64 + x86_64). Pinned
// exactly: VLCKit 4 is still tagged as an alpha and its Objective-C API has
// moved between alphas. The archive is large (~900 MB,
// every Apple platform plus symbols) but SwiftPM caches it once per machine.
// Licence: LGPL-2.1-or-later — Settings › Acknowledgements carries the notice
// and the source offer (https://code.videolan.org/videolan/VLCKit).
let package = Package(
    name: "PlayerKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [.library(name: "PlayerKit", targets: ["PlayerKit"])],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://code.videolan.org/videolan/VLCKit.git", exact: "4.0.0-a25"),
    ],
    targets: [
        .target(
            name: "PlayerKit",
            dependencies: [
                "Core",
                .product(name: "VLCKit", package: "VLCKit"),
            ]
        ),
        .testTarget(name: "PlayerKitTests", dependencies: ["PlayerKit"]),
    ]
)
