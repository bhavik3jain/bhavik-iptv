import Foundation

// The iPhone player's rotate button: portrait ⇄ landscape even with Portrait
// Orientation Lock on. These are its decisions as plain values, so they're
// tested on the Mac; `PlayerOrientationLock` carries them out with UIKit.

/// An interface orientation: UIKit's four, without UIKit.
public enum InterfaceOrientation: Sendable, Hashable, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

/// A set of interface orientations: UIInterfaceOrientationMask without UIKit.
public struct InterfaceOrientations: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ orientation: InterfaceOrientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        }
    }

    public static let portrait = InterfaceOrientations(rawValue: 1 << 0)
    public static let portraitUpsideDown = InterfaceOrientations(rawValue: 1 << 1)
    public static let landscapeLeft = InterfaceOrientations(rawValue: 1 << 2)
    public static let landscapeRight = InterfaceOrientations(rawValue: 1 << 3)
    public static let landscape: InterfaceOrientations = [.landscapeLeft, .landscapeRight]
    public static let allButUpsideDown: InterfaceOrientations = [.portrait, .landscapeLeft, .landscapeRight]
    public static let all: InterfaceOrientations = [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]

    public func contains(_ orientation: InterfaceOrientation) -> Bool {
        contains(InterfaceOrientations(orientation))
    }
}

/// The kind of device, as far as turning the player goes.
public enum RotationIdiom: Sendable, Hashable {
    case phone
    case pad
    /// The Mac, the TV, anything else: never offered.
    case other
}

/// A size class, without UIKit or SwiftUI.
public enum RotationSizeClass: Sendable, Hashable {
    case compact
    case regular
}

/// What the rotate button decides, and what it remembers between a press and
/// the player going away.
///
/// The button asks for the opposite of what the screen shows — portrait from
/// landscape, landscape (right) from portrait — and the app allows only that
/// orientation while it holds. With the lock off, turning the phone itself
/// hands control back to the system, so rotating by hand works as before.
/// When the player closes (or goes to the background bar or picture in
/// picture) the app's own orientations come back, and a player that started
/// in portrait returns to portrait.
public struct PlayerRotation: Sendable, Equatable {
    /// What the button forced, nil while the system decides.
    public private(set) var forced: InterfaceOrientation?
    /// Where the interface was at the first press, to go back to.
    public private(set) var original: InterfaceOrientation?
    /// Where the device itself was at the last press (nil when lying flat),
    /// to tell a real turn of the phone from no turn.
    public private(set) var deviceAtPress: InterfaceOrientation?

    public init() {}

    public var isForcing: Bool { forced != nil }

    // MARK: Decisions

    /// The app's own orientations, the Info.plist lists in project.yml:
    /// everything but upside down on an iPhone (iPhone Duo too), all four on
    /// an iPad. The app delegate's answer replaces those lists, so it must
    /// say the same when nothing is forced (HearthTests checks the two match).
    public static func appOrientations(for idiom: RotationIdiom) -> InterfaceOrientations {
        idiom == .pad ? .all : .allButUpsideDown
    }

    /// Whether the player offers the button: only where iOS honours an
    /// orientation request — an iPhone whose window fills its screen and
    /// isn't regular both ways. Not an iPad (it isn't asked to), not iPhone
    /// Duo's opened inner display (regular × regular, which ignores
    /// orientation), not a window that shares a screen, never the Mac or TV.
    /// A large iPhone in landscape is regular × compact, so it still offers
    /// the way back to portrait.
    public static func isOffered(
        idiom: RotationIdiom,
        horizontal: RotationSizeClass?,
        vertical: RotationSizeClass?,
        fillsScreen: Bool
    ) -> Bool {
        guard idiom == .phone, fillsScreen else { return false }
        return !(horizontal == .regular && vertical == .regular)
    }

    /// Whether a window covers its screen, in either orientation (a moment
    /// mid-rotation can report one turned and the other not yet).
    public static func fills(windowSize: CGSize, screenSize: CGSize, tolerance: CGFloat = 1) -> Bool {
        let window = (min(windowSize.width, windowSize.height), max(windowSize.width, windowSize.height))
        let screen = (min(screenSize.width, screenSize.height), max(screenSize.width, screenSize.height))
        guard screen.0 > 0 else { return false }
        return abs(window.0 - screen.0) <= tolerance && abs(window.1 - screen.1) <= tolerance
    }

    /// What a press asks for: portrait from landscape, landscape right from
    /// portrait (or from an orientation not known yet).
    public static func target(from current: InterfaceOrientation?) -> InterfaceOrientation {
        current?.isLandscape == true ? .portrait : .landscapeRight
    }

    /// What the app allows now: the forced orientation alone while one
    /// holds, the app's own set otherwise.
    public func supportedOrientations(for idiom: RotationIdiom) -> InterfaceOrientations {
        forced.map(InterfaceOrientations.init) ?? Self.appOrientations(for: idiom)
    }

    // MARK: Changes

    /// A press of the button; returns the orientation to ask for. The first
    /// press remembers where the interface started.
    public mutating func press(current: InterfaceOrientation?, device: InterfaceOrientation?) -> InterfaceOrientation {
        let target = Self.target(from: current)
        if forced == nil { original = current }
        forced = target
        deviceAtPress = device
        return target
    }

    /// The phone itself turned. iOS reports that only with the lock off (and
    /// lying flat is reported as nil). A turn to another of the app's
    /// orientations than at the press hands control back to the system,
    /// which then follows the device as it always did; returns true then.
    public mutating func deviceTurned(to device: InterfaceOrientation?, idiom: RotationIdiom) -> Bool {
        guard forced != nil, let device,
              Self.appOrientations(for: idiom).contains(device),
              device != deviceAtPress else { return false }
        reset()
        return true
    }

    /// The player went away. Returns the orientation to ask for on the way
    /// out — portrait, when the first press was made in portrait and the
    /// screen isn't there now — or nil to leave the orientation to the
    /// system. Either way the app's own orientations apply again.
    public mutating func release(current: InterfaceOrientation?) -> InterfaceOrientation? {
        defer { reset() }
        guard forced != nil, original == .portrait, current != .portrait else { return nil }
        return .portrait
    }

    /// iOS refused the request: nothing stays forced.
    public mutating func refused() {
        reset()
    }

    private mutating func reset() {
        forced = nil
        original = nil
        deviceAtPress = nil
    }
}
