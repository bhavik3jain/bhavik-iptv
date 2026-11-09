import CatalogKit
import Core
import Foundation
import HouseholdKit
import Observation

/// Multi-view kept running while someone browses the rest of the app.
///
/// The tiles belong to their screen, which closes them as it goes, so no
/// stream is held for a screen nobody sees. When someone chooses otherwise the
/// session moves here, keeps its who's-watching rows and Stalker keep-alive
/// going, and the next multi-view screen to open takes it back. The app shows
/// the way back (`title`) and owns this; a screen with none just closes its
/// tiles as it always did.
@MainActor
@Observable
public final class MultiViewBackground {
    private(set) var session: MultiViewSession?
    @ObservationIgnored private var upkeep: Task<Void, Never>?
    /// A multi-view screen is opening: one thing at a time, so whatever else
    /// runs in the background stops.
    @ObservationIgnored public var onOpening: (() -> Void)?

    public init() {}

    public var isRunning: Bool { session != nil }

    /// What the button back says: the channel with the sound, and how many
    /// more are running with it.
    public var title: String? {
        session.flatMap { session in
            MultiViewBackgroundText.title(
                audibleChannel: session.audibleOccupant?.channel.name,
                channels: session.occupants.keys.sorted().compactMap { session.occupant(ofTile: $0)?.channel.name }
            )
        }
    }

    /// Holds a screen's tiles. Nothing playing, nothing to hold.
    func keep(_ session: MultiViewSession, catalog: CatalogService, store: HouseholdStore) {
        guard !session.occupants.isEmpty else { return }
        session.collapse()
        self.session = session
        upkeep?.cancel()
        upkeep = Task { [weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MultiViewSession.keepAliveInterval))
                guard !Task.isCancelled, let session else { return }
                await session.upkeep(now: .now, catalog: catalog, store: store)
            }
        }
    }

    /// A multi-view screen is opening; the tiles kept here, if any, are its.
    func take() -> MultiViewSession? {
        onOpening?()
        upkeep?.cancel()
        upkeep = nil
        defer { session = nil }
        return session
    }

    /// Stops every tile and gives its stream back.
    public func stop(store: HouseholdStore) {
        upkeep?.cancel()
        upkeep = nil
        session?.closeAll(store: store)
        session = nil
    }

    /// Tiles another device took over (Continue on Apple TV) stop here, and
    /// with none left the background session ends. Nil when nothing was.
    public func releaseTilesTakenOver(store: HouseholdStore) -> PlaybackTakeover? {
        guard let session, let takeover = session.releaseTilesTakenOver(store: store) else { return nil }
        if session.occupants.isEmpty { stop(store: store) }
        return takeover
    }

    /// The app went behind the TV's Home screen, where its tiles would hold
    /// every stream for nobody (`MultiViewSession.suspend`).
    public func suspend(store: HouseholdStore) {
        session?.suspend(store: store)
    }

    public func resume(catalog: CatalogService, store: HouseholdStore, profileID: UUID?) {
        session?.resume(catalog: catalog, store: store, profileID: profileID)
    }
}

/// The words on the button back to multi-view.
enum MultiViewBackgroundText {
    static func title(audibleChannel: String?, channels: [String]) -> String? {
        guard let first = audibleChannel ?? channels.first else { return nil }
        let others = channels.count - 1
        return others > 0 ? String(localized: "\(first) + \(others) more") : first
    }
}
