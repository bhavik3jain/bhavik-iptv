import Foundation
import PlayerKit
import Testing
import UIKit
@testable import Hearth

// The player's rotate button works through the app delegate's answer to
// "which orientations?", and that answer replaces the Info.plist lists in
// project.yml. With nothing forced it must say exactly what the lists say,
// or the rest of the app quietly loses (or gains) an orientation.

@MainActor
@Suite struct OrientationTests {
    @Test func theAppsOwnOrientationsAreTheInfoPlistLists() throws {
        let url = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let info = try #require(plist as? [String: Any])
        #expect(Self.orientations(info["UISupportedInterfaceOrientations"]) == PlayerRotation.appOrientations(for: .phone))
        #expect(Self.orientations(info["UISupportedInterfaceOrientations~ipad"]) == PlayerRotation.appOrientations(for: .pad))
    }

    @Test func withNothingForcedTheDelegateAnswersTheAppsOwnSet() {
        let mask = AppDelegate().application(UIApplication.shared, supportedInterfaceOrientationsFor: nil)
        let expected: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]
            : [.portrait, .landscapeLeft, .landscapeRight]
        #expect(mask == expected)
    }

    private static func orientations(_ value: Any?) -> InterfaceOrientations? {
        guard let names = value as? [String] else { return nil }
        var result: InterfaceOrientations = []
        for name in names {
            switch name {
            case "UIInterfaceOrientationPortrait": result.insert(.portrait)
            case "UIInterfaceOrientationPortraitUpsideDown": result.insert(.portraitUpsideDown)
            case "UIInterfaceOrientationLandscapeLeft": result.insert(.landscapeLeft)
            case "UIInterfaceOrientationLandscapeRight": result.insert(.landscapeRight)
            default: return nil
            }
        }
        return result
    }
}
