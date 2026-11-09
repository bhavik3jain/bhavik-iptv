import Observation
import SwiftUI

#if os(iOS)
import UIKit
#endif

/// The orientation the iPhone player's rotate button forced, and the app's
/// answer to "which orientations now?" (`PlayerRotation` decides; this
/// carries it out).
///
/// A press asks the player's window scene for the opposite orientation with
/// `requestGeometryUpdate`, which iOS honours even with Portrait Orientation
/// Lock on, after narrowing the app's orientations to that one and telling
/// the window's view controllers (`setNeedsUpdateOfSupportedInterfaceOrientations`).
/// The app delegate reads the narrowed set from `supportedInterfaceOrientations(for:)`;
/// kits never import the app, so this is where it lives. When the player
/// goes, `handBack()` restores the app's own set and, if the player started
/// in portrait, turns back to portrait.
///
/// Everywhere but iOS it never offers the button and does nothing. It reads
/// the window scene a player sits in, never `UIScreen.main` (iPhone Duo).
@MainActor
@Observable
public final class PlayerOrientationLock {
    public static let shared = PlayerOrientationLock()

    /// Whether the player's window can be turned here (an iPhone at compact
    /// size, filling its screen).
    public private(set) var offersRotation = false
    /// The player window's interface orientation, for the button's icon and label.
    public private(set) var interfaceOrientation: InterfaceOrientation = .portrait

    @ObservationIgnored private(set) var rotation = PlayerRotation()

    #if os(iOS)
    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var deviceObserver: (any NSObjectProtocol)?
    #endif

    init() {}

    /// Turns the player's window to the other orientation.
    public func rotate() {
        #if os(iOS)
        guard offersRotation, let scene else { return }
        let target = rotation.press(current: Self.orientation(of: scene), device: Self.deviceOrientation())
        startWatchingDevice()
        apply(in: scene)
        request(target, in: scene)
        #endif
    }

    /// The player closed, or went to the background bar or picture in
    /// picture: the app's own orientations again, and portrait if that's
    /// where the player started. Nothing happens if the button wasn't used.
    public func handBack() {
        #if os(iOS)
        stopWatchingDevice()
        guard rotation.isForcing else { return }
        let current = scene.flatMap(Self.orientation(of:))
        let back = rotation.release(current: current)
        guard let scene else { return }
        apply(in: scene)
        if let back { request(back, in: scene) }
        #endif
    }

    #if os(iOS)
    /// The app delegate's answer (and the scene delegate's, from iOS 27):
    /// the forced orientation for the player's window while the button holds
    /// one, the app's own set (project.yml's Info.plist lists) otherwise.
    public func supportedInterfaceOrientations(for scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        let idiom = RotationIdiom(scene?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom)
        guard rotation.isForcing, scene == nil || scene === self.scene else {
            return UIInterfaceOrientationMask(PlayerRotation.appOrientations(for: idiom))
        }
        return UIInterfaceOrientationMask(rotation.supportedOrientations(for: idiom))
    }

    /// The player's window as it is now (from `PlayerSceneReader`): where a
    /// press goes, and whether the button shows.
    func observe(_ scene: UIWindowScene, window: UIWindow) {
        self.scene = scene
        // The window's traits come from its scene and are current by the
        // time its views lay out after a turn.
        let traits = window.traitCollection
        let offered = PlayerRotation.isOffered(
            idiom: RotationIdiom(traits.userInterfaceIdiom),
            horizontal: RotationSizeClass(traits.horizontalSizeClass),
            vertical: RotationSizeClass(traits.verticalSizeClass),
            fillsScreen: PlayerRotation.fills(windowSize: window.bounds.size, screenSize: scene.screen.bounds.size)
        )
        if offersRotation != offered { offersRotation = offered }
        if let orientation = Self.orientation(of: scene), interfaceOrientation != orientation {
            interfaceOrientation = orientation
        }
    }

    // MARK: UIKit

    /// Tells every view controller of the window that the app's orientations
    /// changed; the presented player decides with the app's mask.
    private func apply(in scene: UIWindowScene) {
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
    }

    private func request(_ orientation: InterfaceOrientation, in scene: UIWindowScene) {
        let mask = UIInterfaceOrientationMask(InterfaceOrientations(orientation))
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
            // Refused (a window sharing its screen, say): don't leave the
            // app held to an orientation it never reached.
            Task { @MainActor in
                guard let self, self.rotation.forced == orientation, let scene = self.scene else { return }
                self.rotation.refused()
                self.stopWatchingDevice()
                self.apply(in: scene)
            }
        }
    }

    /// With the lock off, turning the phone hands control back to the
    /// system; iOS reports no turns while the lock is on.
    private func startWatchingDevice() {
        guard deviceObserver == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        deviceObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceTurned() }
        }
    }

    private func stopWatchingDevice() {
        guard let deviceObserver else { return }
        NotificationCenter.default.removeObserver(deviceObserver)
        self.deviceObserver = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func deviceTurned() {
        let idiom = RotationIdiom(UIDevice.current.userInterfaceIdiom)
        guard rotation.deviceTurned(to: Self.deviceOrientation(), idiom: idiom) else { return }
        stopWatchingDevice()
        if let scene { apply(in: scene) }
    }

    private static func orientation(of scene: UIWindowScene) -> InterfaceOrientation? {
        InterfaceOrientation(scene.effectiveGeometry.interfaceOrientation)
    }

    /// The device's own position as the interface orientation that matches
    /// it (the device turned left shows landscape right); nil lying flat.
    private static func deviceOrientation() -> InterfaceOrientation? {
        switch UIDevice.current.orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }
    #endif
}

#if os(iOS)
extension InterfaceOrientation {
    init?(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}

extension UIInterfaceOrientationMask {
    init(_ orientations: InterfaceOrientations) {
        var mask: UIInterfaceOrientationMask = []
        if orientations.contains(.portrait) { mask.insert(.portrait) }
        if orientations.contains(.portraitUpsideDown) { mask.insert(.portraitUpsideDown) }
        if orientations.contains(.landscapeLeft) { mask.insert(.landscapeLeft) }
        if orientations.contains(.landscapeRight) { mask.insert(.landscapeRight) }
        self = mask
    }
}

extension RotationIdiom {
    init(_ idiom: UIUserInterfaceIdiom) {
        switch idiom {
        case .phone: self = .phone
        case .pad: self = .pad
        default: self = .other
        }
    }
}

extension RotationSizeClass {
    init?(_ sizeClass: UIUserInterfaceSizeClass) {
        switch sizeClass {
        case .compact: self = .compact
        case .regular: self = .regular
        default: return nil
        }
    }
}

/// Reports the player's window scene to `PlayerOrientationLock`: when it
/// joins a window, when its size changes (a rotation), and when the size
/// classes change (iPhone Duo opening or folding).
struct PlayerSceneReader: UIViewRepresentable {
    func makeUIView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (view: ReaderView, _) in
                view.report()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let window, let scene = window.windowScene else { return }
            PlayerOrientationLock.shared.observe(scene, window: window)
        }
    }
}
#endif

extension View {
    /// The player screen's part in the rotate button: on iOS it tells the
    /// lock which window the player is in, and hands the orientation back
    /// when the player leaves the screen (closed, kept in the background, or
    /// a multi-view tile shrunk back). Nothing elsewhere.
    func playerOrientationSupport() -> some View {
        #if os(iOS)
        background(PlayerSceneReader().allowsHitTesting(false).accessibilityHidden(true))
            .onDisappear { PlayerOrientationLock.shared.handBack() }
        #else
        self
        #endif
    }
}
