import Foundation

/// Makes the engines a `PlayerModel` runs. The standard factory makes
/// `AVPlayerEngine` and, when VLCKit is linked, `VLCEngine`; tests inject a
/// factory of fakes so the retry and event logic runs with no real player.
public struct PlaybackEngineFactory: Sendable {
    /// The engines this factory can make. `EnginePlan` falls back to AVPlayer
    /// when the chooser's pick isn't here.
    public var availableKinds: Set<EngineKind>
    private let make: @MainActor @Sendable (EngineKind) -> (any PlaybackEngine)?

    public init(availableKinds: Set<EngineKind>, make: @escaping @MainActor @Sendable (EngineKind) -> (any PlaybackEngine)?) {
        self.availableKinds = availableKinds
        self.make = make
    }

    @MainActor
    public func makeEngine(_ kind: EngineKind) -> (any PlaybackEngine)? {
        guard availableKinds.contains(kind) else { return nil }
        return make(kind)
    }

    /// AVPlayer always; VLCKit when the package resolved and linked it.
    public static let standard = PlaybackEngineFactory(availableKinds: VLCKitInfo.isLinked ? [.avPlayer, .vlc] : [.avPlayer]) { kind in
        switch kind {
        case .avPlayer:
            return AVPlayerEngine()
        case .vlc:
            #if canImport(VLCKit)
            return VLCEngine()
            #else
            return nil
            #endif
        }
    }
}

/// What Settings › Acknowledgements says about VLCKit, the app's only remote
/// dependency. The LGPL asks that users know it is there, what their rights
/// are, and where the source is.
public enum VLCKitInfo {
    /// False when PlayerKit was built without VLCKit; every stream then goes
    /// to AVPlayer and VLC-only formats say so when they fail.
    public static var isLinked: Bool {
        #if canImport(VLCKit)
        true
        #else
        false
        #endif
    }

    /// The exact version pinned in PlayerKit's Package.swift.
    public static let version = "4.0.0-a25"
    public static let license = "GNU Lesser General Public License v2.1 or later"
    public static let sourceURL = URL(string: "https://code.videolan.org/videolan/VLCKit")!
    public static let licenseURL = URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")!
    /// The acknowledgement paragraph, ready to show.
    public static var notice: String {
        String(localized: """
        Hearth plays some streams with VLCKit \(version) by VideoLAN, used unmodified as a dynamically linked framework under the \(license). You may replace it with your own build of VLCKit; its complete source code is available at \(sourceURL.absoluteString).
        """)
    }
}
