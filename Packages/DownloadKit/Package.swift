// swift-tools-version: 6.0
import PackageDescription

// DownloadKit depends on nothing. Movies and episodes saved on this device to
// watch offline (DL-1): the records, their files, and the system's download
// sessions (HLS packages through AVFoundation, plain files through
// URLSession). It never talks to a provider: the app resolves each link
// through CatalogKit and hands it over, and accounts for the stream a running
// download takes (DL-2). The Apple TV has no HLS downloads and keeps none.
let package = Package(
    name: "DownloadKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [.library(name: "DownloadKit", targets: ["DownloadKit"])],
    targets: [
        .target(name: "DownloadKit"),
        .testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit"]),
    ]
)
