import CoreGraphics
import Testing
@testable import PlayerKit

// The iPhone player's rotate button as plain values: where it shows, what a
// press asks for, what the app allows while it holds and after the player goes.

@Suite("PlayerRotation")
struct PlayerRotationTests {
    // MARK: Where the button shows

    @Test func offeredOnAnIPhoneInPortraitAndLandscape() {
        // Portrait: compact × regular.
        #expect(PlayerRotation.isOffered(idiom: .phone, horizontal: .compact, vertical: .regular, fillsScreen: true))
        // Landscape on a small iPhone: compact × compact.
        #expect(PlayerRotation.isOffered(idiom: .phone, horizontal: .compact, vertical: .compact, fillsScreen: true))
        // Landscape on a Max: regular × compact, still the way back to portrait.
        #expect(PlayerRotation.isOffered(idiom: .phone, horizontal: .regular, vertical: .compact, fillsScreen: true))
    }

    @Test func notOnIPhoneDuosOpenedInnerDisplay() {
        // Regular × regular ignores orientation requests.
        #expect(!PlayerRotation.isOffered(idiom: .phone, horizontal: .regular, vertical: .regular, fillsScreen: true))
    }

    @Test func notInAWindowThatSharesItsScreen() {
        #expect(!PlayerRotation.isOffered(idiom: .phone, horizontal: .compact, vertical: .regular, fillsScreen: false))
    }

    @Test(arguments: [RotationIdiom.pad, .other])
    func neverOffIPhone(idiom: RotationIdiom) {
        for horizontal in [RotationSizeClass.compact, .regular, nil] {
            for vertical in [RotationSizeClass.compact, .regular, nil] {
                #expect(!PlayerRotation.isOffered(idiom: idiom, horizontal: horizontal, vertical: vertical, fillsScreen: true))
            }
        }
    }

    @Test func fillsScreenInEitherOrientation() {
        let screen = CGSize(width: 440, height: 956)
        #expect(PlayerRotation.fills(windowSize: screen, screenSize: screen))
        #expect(PlayerRotation.fills(windowSize: CGSize(width: 956, height: 440), screenSize: screen))
        #expect(PlayerRotation.fills(windowSize: CGSize(width: 439.5, height: 956), screenSize: screen))
        #expect(!PlayerRotation.fills(windowSize: CGSize(width: 320, height: 956), screenSize: screen))
        #expect(!PlayerRotation.fills(windowSize: screen, screenSize: .zero))
    }

    // MARK: What a press asks for

    @Test func pressAsksForTheOtherOrientation() {
        #expect(PlayerRotation.target(from: .portrait) == .landscapeRight)
        #expect(PlayerRotation.target(from: .portraitUpsideDown) == .landscapeRight)
        #expect(PlayerRotation.target(from: .landscapeLeft) == .portrait)
        #expect(PlayerRotation.target(from: .landscapeRight) == .portrait)
        #expect(PlayerRotation.target(from: nil) == .landscapeRight)
    }

    // MARK: What the app allows

    @Test func appOrientationsMatchTheInfoPlistLists() {
        #expect(PlayerRotation.appOrientations(for: .phone) == [.portrait, .landscapeLeft, .landscapeRight])
        #expect(PlayerRotation.appOrientations(for: .pad) == .all)
    }

    @Test func nothingForcedAllowsTheAppsOwnSet() {
        let rotation = PlayerRotation()
        #expect(!rotation.isForcing)
        #expect(rotation.supportedOrientations(for: .phone) == .allButUpsideDown)
        #expect(rotation.supportedOrientations(for: .pad) == .all)
    }

    @Test func aPressAllowsOnlyWhatItAskedFor() {
        var rotation = PlayerRotation()
        let target = rotation.press(current: .portrait, device: .portrait)
        #expect(target == .landscapeRight)
        #expect(rotation.supportedOrientations(for: .phone) == .landscapeRight)

        let back = rotation.press(current: .landscapeRight, device: .portrait)
        #expect(back == .portrait)
        #expect(rotation.supportedOrientations(for: .phone) == .portrait)
    }

    // MARK: Handing back

    @Test func closingAfterStartingInPortraitReturnsToPortrait() {
        var rotation = PlayerRotation()
        _ = rotation.press(current: .portrait, device: .portrait)
        let back = rotation.release(current: .landscapeRight)
        #expect(back == .portrait)
        #expect(!rotation.isForcing)
        #expect(rotation.supportedOrientations(for: .phone) == .allButUpsideDown)
    }

    @Test func theFirstPressDecidesWhereToReturn() {
        var rotation = PlayerRotation()
        _ = rotation.press(current: .portrait, device: .portrait)
        _ = rotation.press(current: .landscapeRight, device: .portrait)
        _ = rotation.press(current: .portrait, device: .portrait)
        #expect(rotation.original == .portrait)
        let back = rotation.release(current: .landscapeRight)
        #expect(back == .portrait)
    }

    @Test func closingAlreadyInPortraitAsksForNothing() {
        var rotation = PlayerRotation()
        _ = rotation.press(current: .portrait, device: .portrait)
        _ = rotation.press(current: .landscapeRight, device: .portrait)
        let back = rotation.release(current: .portrait)
        #expect(back == nil)
        #expect(rotation.supportedOrientations(for: .phone) == .allButUpsideDown)
    }

    @Test func closingAfterStartingInLandscapeLeavesItToTheSystem() {
        var rotation = PlayerRotation()
        // Turned to portrait, then back to landscape with a second press.
        _ = rotation.press(current: .landscapeLeft, device: .landscapeLeft)
        _ = rotation.press(current: .portrait, device: .landscapeLeft)
        #expect(rotation.original == .landscapeLeft)
        let back = rotation.release(current: .landscapeRight)
        #expect(back == nil)
        #expect(!rotation.isForcing)
    }

    @Test func closingWithoutAPressAsksForNothing() {
        var rotation = PlayerRotation()
        let back = rotation.release(current: .landscapeRight)
        #expect(back == nil)
        #expect(rotation == PlayerRotation())
    }

    @Test func aRefusedRequestLeavesNothingForced() {
        var rotation = PlayerRotation()
        _ = rotation.press(current: .portrait, device: .portrait)
        rotation.refused()
        #expect(!rotation.isForcing)
        let back = rotation.release(current: .portrait)
        #expect(back == nil)
    }

    // MARK: Turning the phone by hand (lock off)

    @Test func turningThePhoneHandsControlBack() {
        var rotation = PlayerRotation()
        _ = rotation.press(current: .portrait, device: .portrait)
        // Turned to landscape to watch: the system follows the device again.
        let handedBack = rotation.deviceTurned(to: .landscapeRight, idiom: .phone)
        #expect(handedBack)
        #expect(!rotation.isForcing)
        #expect(rotation.supportedOrientations(for: .phone) == .allButUpsideDown)
        // And closing then leaves the orientation alone.
        let back = rotation.release(current: .landscapeRight)
        #expect(back == nil)
    }

    @Test func noTurnKeepsTheForcedOrientation() {
        var rotation = PlayerRotation()
        _ = rotation.press(current: .portrait, device: .portrait)
        // Lying flat, then back where it was at the press.
        let flat = rotation.deviceTurned(to: nil, idiom: .phone)
        #expect(!flat)
        let same = rotation.deviceTurned(to: .portrait, idiom: .phone)
        #expect(!same)
        #expect(rotation.forced == .landscapeRight)
    }

    @Test func upsideDownOnAnIPhoneIsNotATurn() {
        var rotation = PlayerRotation()
        _ = rotation.press(current: .portrait, device: .portrait)
        let upsideDown = rotation.deviceTurned(to: .portraitUpsideDown, idiom: .phone)
        #expect(!upsideDown)
        #expect(rotation.isForcing)
    }

    @Test func pickedUpFromFlatFollowsTheDevice() {
        var rotation = PlayerRotation()
        _ = rotation.press(current: .portrait, device: nil)
        let handedBack = rotation.deviceTurned(to: .portrait, idiom: .phone)
        #expect(handedBack)
        #expect(!rotation.isForcing)
    }

    @Test func turnsWithoutAPressChangeNothing() {
        var rotation = PlayerRotation()
        let handedBack = rotation.deviceTurned(to: .landscapeLeft, idiom: .phone)
        #expect(!handedBack)
        #expect(rotation == PlayerRotation())
    }
}
