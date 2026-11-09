import Foundation
import SwiftUI

/// Carry on here with what another device of the household is playing
/// (Continue on Apple TV, docs/designs/continue-on-tv.md): the same channel,
/// the same multi-view, or a movie or episode from where it is. The app ends
/// the other device's who's-watching rows, which frees their streams and
/// stops that device once it sees this one playing.
public struct ContinueHereRequest: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// A channel live, or a movie or episode (no start position: the
        /// player starts from the profile's saved progress).
        case play(PlayIntent)
        /// Multi-view with these channels in tile order.
        case multiView(channelKeys: [String])
    }

    public var content: Content
    /// The other device's rows (HouseholdKit's `ContinueOffer.playbackIDs`).
    public var endingPlaybackIDs: [UUID]
    /// "Bhavik's iPhone", for what the app says if it can't.
    public var deviceName: String

    public init(content: Content, endingPlaybackIDs: [UUID], deviceName: String) {
        self.content = content
        self.endingPlaybackIDs = endingPlaybackIDs
        self.deviceName = deviceName
    }
}

/// `@Environment(\.continueHere)`. The default does nothing, so previews and
/// tests never need a player.
public struct ContinueHereAction: Sendable {
    private let handler: @MainActor @Sendable (ContinueHereRequest) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (ContinueHereRequest) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ request: ContinueHereRequest) {
        handler(request)
    }
}

extension EnvironmentValues {
    @Entry public var continueHere = ContinueHereAction { _ in }
}
