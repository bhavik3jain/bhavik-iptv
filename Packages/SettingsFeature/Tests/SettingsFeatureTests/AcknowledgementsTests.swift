import Foundation
import Testing
@testable import SettingsFeature

@Suite struct AcknowledgementsTests {
    /// PlayerKit's manifest, read from the checkout beside this package.
    private var playerKitManifest: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SettingsFeatureTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SettingsFeature
            .deletingLastPathComponent() // Packages
            .appendingPathComponent("PlayerKit/Package.swift")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func vlcKitVersionMatchesPlayerKitsPin() throws {
        // Settings can't import PlayerKit, so the LGPL notice carries the
        // version itself; this catches the pin moving without it.
        let manifest = try #require(playerKitManifest, "PlayerKit/Package.swift not found beside SettingsFeature")
        #expect(manifest.contains(#"exact: "\#(Acknowledgements.vlcKitVersion)""#))
        #expect(manifest.contains(Acknowledgements.vlcKitPackageURL.absoluteString))
    }

    @Test func theNoticeAndSourceOfferNameTheVersion() {
        #expect(Acknowledgements.vlcKitNotice.contains("VLCKit \(Acknowledgements.vlcKitVersion)"))
        #expect(Acknowledgements.vlcKitNotice.contains(Acknowledgements.vlcKitLicenseName))
        #expect(Acknowledgements.vlcKitSourceOffer.contains("VLCKit \(Acknowledgements.vlcKitVersion)"))
    }

    @Test func linksAreSecure() {
        let urls = [
            Acknowledgements.vlcKitPackageURL, Acknowledgements.vlcKitSourceURL, Acknowledgements.vlcKitLicenseURL,
            Acknowledgements.vlcSourceURL, Acknowledgements.fontLicenseURL, Acknowledgements.appleSamplesURL,
        ] + Acknowledgements.fonts.map(\.projectURL)
        for url in urls {
            #expect(url.scheme == "https", "\(url) is not https")
        }
    }

    @Test func everyBundledFontIsListed() {
        let names = Acknowledgements.fonts.map(\.name)
        #expect(names == ["Sora", "IBM Plex Sans", "IBM Plex Mono"])
        #expect(Set(Acknowledgements.fonts.map(\.id)).count == names.count)
        #expect(Acknowledgements.fonts.allSatisfy { !$0.role.isEmpty && !$0.copyright.isEmpty })
    }

    @Test func theFontLicenceShipsWithThePackage() throws {
        let text = try #require(Acknowledgements.fontLicenseText())
        #expect(text.contains("SIL OPEN FONT LICENSE Version 1.1"))
        for font in Acknowledgements.fonts {
            #expect(text.contains(font.name), "OFL.txt doesn't mention \(font.name)")
        }
    }

    @Test func aBundleWithoutTheLicenceGivesNil() {
        #expect(Acknowledgements.fontLicenseText(bundle: Bundle(for: BundleMarker.self)) == nil)
    }
}

/// A class in the test bundle, to name a bundle that has no OFL.txt.
private final class BundleMarker {}
