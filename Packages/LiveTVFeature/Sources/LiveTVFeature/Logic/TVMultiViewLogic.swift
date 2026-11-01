import Foundation

// Multi-view on the Apple TV as values: what the remote's buttons do, and
// where focus goes. The TV has no touch or drag, so these rules are what makes
// the screen usable.

/// Where focus can be on the TV's multi-view screen.
enum TVMultiViewFocus: Hashable, Sendable {
    case tile(Int)
    case arrangement(MultiViewArrangement)
}

/// What Select does on a tile: more of that tile each time. An empty one
/// takes a channel, a failed one tries again, a playing one takes the sound,
/// and the one with the sound goes full screen.
enum TVTileAction: Hashable, Sendable {
    case addChannel
    case retry
    case giveSound
    case fullScreen

    static func onSelect(isEmpty: Bool, hasFailed: Bool, hasSound: Bool) -> TVTileAction {
        if isEmpty { return .addChannel }
        if hasFailed { return .retry }
        return hasSound ? .fullScreen : .giveSound
    }

    /// The line a focused playing tile shows, so a remote's two gestures can
    /// be found without a manual, and what VoiceOver reads on any tile.
    var hint: String {
        switch self {
        case .addChannel: String(localized: "Select to add a channel")
        case .retry: String(localized: "Select to try again · Hold for more")
        case .giveSound: String(localized: "Select to hear this tile · Hold for more")
        case .fullScreen: String(localized: "Select for full screen · Hold for more")
        }
    }
}

/// Where focus belongs on the screen, given what is showing.
enum TVMultiViewFocusRules {
    /// A slot as these rules see it.
    struct Slot: Hashable, Sendable {
        var id: Int
        var isEmpty: Bool
    }

    /// On opening: the first tile still waiting for a channel, which is the
    /// next thing to do; with every tile playing, the one with the sound.
    static func initial(slots: [Slot], audibleTileID: Int?) -> TVMultiViewFocus {
        if let empty = slots.first(where: \.isEmpty) { return .tile(empty.id) }
        if let audibleTileID, slots.contains(where: { $0.id == audibleTileID }) { return .tile(audibleTileID) }
        return .tile(slots.first?.id ?? 0)
    }

    /// After a channel is picked for a tile: on to the next empty tile while
    /// a source has a stream free, so channels go in one after another; else
    /// it stays on the tile, whose Select is then the next thing to do.
    static func afterPicking(tile id: Int, slots: [Slot], hasRoomForAnother: Bool) -> TVMultiViewFocus {
        guard hasRoomForAnother else { return .tile(id) }
        let empties = slots.filter { $0.isEmpty && $0.id != id }
        return .tile((empties.first { $0.id > id } ?? empties.first)?.id ?? id)
    }
}

/// What Menu does on the screen: the picker first, then the full-screen
/// player, then multi-view itself. Never nothing, and never out of the app.
enum TVMultiViewBack: Hashable, Sendable {
    case closePicker
    case closeFullScreen
    case leave

    static func onMenu(hasPicker: Bool, hasFullScreen: Bool) -> TVMultiViewBack {
        if hasPicker { return .closePicker }
        if hasFullScreen { return .closeFullScreen }
        return .leave
    }
}

/// Whether a channel in the picker can be chosen, and what its row says if
/// not: it is on screen already, or its source is at its stream limit.
enum MultiViewChannelAvailability: Hashable, Sendable {
    case available
    case onScreen
    case sourceFull(String)

    var note: String? {
        switch self {
        case .available: nil
        case .onScreen: String(localized: "On screen")
        case .sourceFull(let note): note
        }
    }

    static func of(isOnScreen: Bool, source: SourceStreamState?) -> MultiViewChannelAvailability {
        if isOnScreen { return .onScreen }
        if let source, let note = StreamLimitAdvice.channelNote(source) { return .sourceFull(note) }
        return .available
    }
}

/// The channel multi-view opens with (the one the player was showing): it
/// takes a tile only if its source has a stream free, since the player's own
/// stream has already been given back by then.
enum MultiViewStart {
    static func canPlay(sourceID: UUID, states: [SourceStreamState]) -> Bool {
        !(states.first { $0.sourceID == sourceID }?.isFull ?? false)
    }
}

/// Which tiles reopen when the app comes back from the background, having
/// given their streams back: in slot order, as many as each source still has
/// room for, since someone else may have taken them meanwhile.
enum MultiViewResume {
    struct Saved: Hashable, Sendable {
        var tileID: Int
        var sourceID: UUID
    }

    static func tilesToReopen(_ saved: [Saved], states: [SourceStreamState]) -> [Int] {
        var reopened: [UUID: Int] = [:]
        return saved.sorted { $0.tileID < $1.tileID }.compactMap { tile in
            let state = states.first { $0.sourceID == tile.sourceID }
            let inUse = (state?.inUse ?? 0) + reopened[tile.sourceID, default: 0]
            if let limit = state?.limit, inUse >= limit { return nil }
            reopened[tile.sourceID, default: 0] += 1
            return tile.tileID
        }
    }
}

/// The picker's focus: the search field, a category, or a channel.
enum TVChannelPickerFocus: Hashable, Sendable {
    case search
    case clearSearch
    case chip(String)
    case channel(String)

    /// On opening: the first channel that can be chosen, or failing that the
    /// first in the list, or the search field, which is always there.
    /// Something must be able to take focus or Menu reaches nothing.
    static func initial(channelKeys: [String], firstAvailableKey: String?) -> TVChannelPickerFocus {
        if let firstAvailableKey { return .channel(firstAvailableKey) }
        if let first = channelKeys.first { return .channel(first) }
        return .search
    }

    /// Whether focus has somewhere valid to be: a channel no longer listed
    /// (the category changed, a search narrowed it) has gone.
    func isValid(channelKeys: Set<String>, chipIDs: Set<String>, isSearching: Bool) -> Bool {
        switch self {
        case .search: true
        case .clearSearch: isSearching
        case .chip(let id): !isSearching && chipIDs.contains(id)
        case .channel(let key): channelKeys.contains(key)
        }
    }
}
