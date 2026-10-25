import Foundation

/// What Settings › Acknowledgements says, as data: the open-source pieces
/// Hearth ships or uses, their licences, and VLCKit's source offer.
///
/// VLCKit's facts mirror PlayerKit's exact pin (`Packages/PlayerKit/
/// Package.swift`, `exact: "4.0.0-a25"`) and its public `VLCKitInfo`. This
/// package doesn't import PlayerKit — that would drag VLCKit's binary into
/// every build of Settings for one string — so when PlayerKit's pin moves,
/// `vlcKitVersion` moves with it.
enum Acknowledgements {
    // MARK: VLCKit (LGPL-2.1-or-later)

    static let vlcKitName = "VLCKit"
    /// PlayerKit's `.package(url: "https://code.videolan.org/videolan/VLCKit.git", exact: "4.0.0-a25")`.
    static let vlcKitVersion = "4.0.0-a25"
    static let vlcKitPackageURL = URL(string: "https://code.videolan.org/videolan/VLCKit.git")!
    static let vlcKitSourceURL = URL(string: "https://code.videolan.org/videolan/VLCKit")!
    static let vlcKitLicenseName = "GNU Lesser General Public License v2.1 or later"
    static let vlcKitLicenseURL = URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")!
    /// libVLC and the codecs inside VLCKit.xcframework, whose own source is
    /// VideoLAN's too.
    static let vlcSourceURL = URL(string: "https://code.videolan.org/videolan/vlc")!

    static var vlcKitNotice: String {
        String(localized: "Hearth plays some streams (raw MPEG-TS, MKV and other formats AVPlayer can't open) with \(vlcKitName) \(vlcKitVersion) by VideoLAN, which includes libVLC. It is used unmodified, as a dynamically linked framework, under the \(vlcKitLicenseName). You may replace it with your own build of \(vlcKitName); the licence gives you that right, and Hearth's use of the framework doesn't restrict it.", bundle: .module)
    }

    /// The LGPL's written offer of source (section 6).
    static var vlcKitSourceOffer: String {
        String(localized: "Source offer: the complete corresponding source code of \(vlcKitName) \(vlcKitVersion) and libVLC, as used in this app, is available from VideoLAN at the addresses below. If you can't get it there, ask through this build's TestFlight feedback and we will send you a copy, for at least three years after this version is distributed, at no more than the cost of sending it.", bundle: .module)
    }

    // MARK: Fonts (SIL OFL 1.1)

    struct Font: Identifiable, Hashable, Sendable {
        var name: String
        var role: String
        var copyright: String
        var projectURL: URL
        var id: String { name }
    }

    static var fonts: [Font] {
        [
            Font(
                name: "Sora",
                role: String(localized: "Titles", bundle: .module, comment: "What the Sora typeface is used for"),
                copyright: "Copyright 2019 The Sora Project Authors",
                projectURL: URL(string: "https://github.com/sora-xor/sora-font")!
            ),
            Font(
                name: "IBM Plex Sans",
                role: String(localized: "Text", bundle: .module, comment: "What the IBM Plex Sans typeface is used for"),
                copyright: "Copyright © 2017 IBM Corp. with Reserved Font Name \"Plex\"",
                projectURL: URL(string: "https://github.com/IBM/plex")!
            ),
            Font(
                name: "IBM Plex Mono",
                role: String(localized: "Times and numbers", bundle: .module, comment: "What the IBM Plex Mono typeface is used for"),
                copyright: "Copyright © 2017 IBM Corp. with Reserved Font Name \"Plex\"",
                projectURL: URL(string: "https://github.com/IBM/plex")!
            ),
        ]
    }

    static let fontLicenseName = "SIL Open Font License 1.1"
    static let fontLicenseURL = URL(string: "https://openfontlicense.org")!

    /// The full licence text, bundled with this package (the same file Core
    /// ships beside the fonts, Resources/Fonts/OFL.txt). Nil only if the
    /// resource went missing from the build.
    static func fontLicenseText(bundle: Bundle = .module) -> String? {
        guard let url = bundle.url(forResource: "OFL", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Apple's HLS samples

    static let appleSamplesURL = URL(string: "https://developer.apple.com/streaming/examples/")!

    static var appleSamplesNotice: String {
        String(localized: "The demo provider, which only development builds turn on, plays Apple's public HLS example streams from developer.apple.com, unmodified, as test content. They are streamed from Apple, not shipped in the app, and remain Apple's.", bundle: .module)
    }
}
