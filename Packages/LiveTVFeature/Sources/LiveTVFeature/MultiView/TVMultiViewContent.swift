import CatalogKit
import Core
import HouseholdKit
import PlayerKit
import SwiftUI

/// What the TV's channel picker is filling.
private struct TVPickerRequest: Identifiable {
    var tileID: Int
    /// Swapping a playing tile: its own stream doesn't count against its
    /// source while picking.
    var isSwap: Bool
    var id: Int { tileID }
}

/// Multi-view on the Apple TV (PLY-9), driven by the Siri Remote: `MultiView
/// Content` taps, drags and long-presses a picture, none of which the TV has.
///
/// The arrows walk the tiles and, up from the top row, the layout buttons.
/// Select is more of the focused tile: an empty one opens the channel picker,
/// a playing one takes the sound, and the one with the sound goes full screen
/// (`TVTileAction`). Press and hold has the rest, as in the guide. Menu backs
/// out one thing at a time and closes every tile on the way out, and Home gives
/// the streams back until the app returns, so no stream is held for a screen
/// nobody sees.
///
/// The picker and a tile taken full screen draw over the tiles in this same
/// presentation, with the tiles disabled behind them, rather than as covers of
/// their own: a dismissing cover handed focus to the guide behind multi-view,
/// out of sight, where the next press would act on a screen nobody can see.
struct TVMultiViewContent: View {
    /// The channel to open with, from the player or the guide.
    let startingChannelKey: String?
    /// Menu left the screen; nil dismisses it.
    let onClose: (() -> Void)?

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("liveTV.multiView.arrangement") private var arrangementRaw = MultiViewArrangement.four.rawValue
    @State private var multiView = MultiViewSession()
    @State private var picker: TVPickerRequest?
    @State private var lastFocus: TVMultiViewFocus?
    @State private var didStart = false
    @FocusState private var focus: TVMultiViewFocus?

    private static let spacing: CGFloat = 24

    var body: some View {
        ZStack {
            tiles
                .disabled(isCovered)
            if let expanded = multiView.expanded {
                PlayerView(model: expanded.player)
                    .ignoresSafeArea()
            } else if let picker {
                TVMultiViewChannelPicker(
                    title: picker.isSwap ? String(localized: "Change channel") : String(localized: "Add a channel"),
                    states: multiView.streamStates(catalog: catalog, store: store, excludingTile: picker.isSwap ? picker.tileID : nil),
                    onScreen: multiView.channelKeysOnScreen,
                    onCancel: { self.picker = nil },
                    onPick: { channel in
                        self.picker = nil
                        play(channel, inTile: picker.tileID)
                        lastFocus = focusAfterPicking(tile: picker.tileID)
                    }
                )
            }
        }
        .hearthOnExitCommand(handleMenu)
        .task {
            // Who's-watching heartbeats and the Stalker watchdog while tiles
            // play; the session decides which are due.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MultiViewSession.keepAliveInterval))
                guard !Task.isCancelled else { return }
                await multiView.upkeep(now: .now, catalog: catalog, store: store)
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            // Swapping the player's cover for this one appears, disappears
            // and appears again, so the next appearance starts afresh.
            multiView.closeAll(store: store)
            didStart = false
        }
        .onChange(of: session.currentProfile?.id) { _, _ in
            // A different profile mustn't inherit the last one's tiles (or
            // its who's-watching rows).
            multiView.closeAll(store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            // The app keeps running behind the Home screen for its sound, and
            // the tiles would hold every stream for a screen nobody sees.
            switch phase {
            case .background: multiView.suspend(store: store)
            case .active: multiView.resume(catalog: catalog, store: store, profileID: session.currentProfile?.id)
            default: break
            }
        }
        .onChange(of: focus) { _, newValue in
            if let newValue { lastFocus = newValue }
        }
        .onChange(of: isCovered) { _, covered in
            // Back from the picker or the player: to the tile it opened from.
            if !covered { focus = lastFocus }
        }
    }

    private var isCovered: Bool {
        picker != nil || multiView.expanded != nil
    }

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 20) {
            bar
                .hearthFocusSection()
            grid
                .hearthFocusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .hearthScreenBackground()
        // As the tiles come back from under the picker or the player, the
        // system's own move lands where the one above is sending it.
        .defaultFocus($focus, lastFocus ?? initialFocus)
    }

    private var initialFocus: TVMultiViewFocus {
        TVMultiViewFocusRules.initial(
            slots: multiView.visibleTiles.map { .init(id: $0.id, isEmpty: $0.isEmpty) },
            audibleTileID: multiView.audibleTileID
        )
    }

    // MARK: Bar

    /// The title, the layouts, and whose sound plays.
    private var bar: some View {
        HStack(spacing: 28) {
            Text("Multi-view")
                .font(.hearthTVTitle)
                .tracking(-0.5)
                .foregroundStyle(HearthColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize()
            arrangementButtons
            Spacer(minLength: 20)
            soundLabel
        }
        .frame(height: 78)
    }

    private var arrangementButtons: some View {
        HStack(spacing: 16) {
            ForEach(MultiViewArrangement.allCases) { arrangement in
                let isSelected = multiView.arrangement == arrangement
                Button {
                    setArrangement(arrangement)
                } label: {
                    Image(systemName: arrangement.systemImage)
                        .font(.system(size: 30, weight: .medium))
                        .frame(minWidth: 40)
                }
                .buttonStyle(.hearthTV(isSelected: isSelected))
                .focused($focus, equals: .arrangement(arrangement))
                .accessibilityLabel(Text(arrangement.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
    }

    @ViewBuilder
    private var soundLabel: some View {
        if let name = multiView.model.audibleItemName {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(HearthColor.accent)
                    .accessibilityHidden(true)
                Text("Sound from \(name)")
                    .lineLimit(1)
            }
            .font(.hearthTVCallout)
            .foregroundStyle(HearthColor.textSecondary)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { proxy in
            let tiles = multiView.visibleTiles
            let geometry = MultiViewGridGeometry.make(tileCount: tiles.count, available: proxy.size, spacing: Self.spacing)
            let rows = MultiViewGridGeometry.rows(of: tiles, columns: geometry.columns)
            VStack(spacing: Self.spacing) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: Self.spacing) {
                        ForEach(rows[index]) { tile in
                            tileView(tile)
                                .frame(width: geometry.tileSize.width, height: geometry.tileSize.height)
                                .zIndex(focus == .tile(tile.id) ? 1 : 0)
                        }
                    }
                    .zIndex(rows[index].contains { focus == .tile($0.id) } ? 1 : 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func tileView(_ tile: MultiViewModel.Tile) -> some View {
        let action = action(on: tile)
        return TVPlayerTile(content: content(of: tile), hint: action.hint) {
            perform(action, on: tile.id)
        }
        .focused($focus, equals: .tile(tile.id))
        .contextMenu {
            if !tile.isEmpty { tileMenu(tile.id) }
        }
    }

    private func content(of tile: MultiViewModel.Tile) -> TVPlayerTile.Content {
        if multiView.expanded?.tileID == tile.id {
            return .fullScreen(name: multiView.occupant(ofTile: tile.id)?.channel.name)
        }
        if let player = tile.player {
            return .playing(
                player,
                hasSound: tile.id == multiView.audibleTileID,
                sourceName: multiView.occupant(ofTile: tile.id).flatMap { SourceLabel.name(for: $0.channel, catalog: catalog) }
            )
        }
        return .empty(reason: StreamLimitAdvice.emptyTileReason(multiView.streamStates(catalog: catalog, store: store)))
    }

    private func action(on tile: MultiViewModel.Tile) -> TVTileAction {
        TVTileAction.onSelect(
            isEmpty: tile.isEmpty,
            hasFailed: tile.player?.state.failureMessage != nil,
            hasSound: tile.id == multiView.audibleTileID
        )
    }

    @ViewBuilder
    private func tileMenu(_ id: Int) -> some View {
        if multiView.audibleTileID != id {
            Button {
                multiView.giveSound(toTile: id)
            } label: {
                Label("Play this tile's sound", systemImage: "speaker.wave.2")
            }
        }
        Button {
            multiView.expand(tile: id)
        } label: {
            Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Button {
            picker = TVPickerRequest(tileID: id, isSwap: true)
        } label: {
            Label("Change channel", systemImage: "arrow.left.arrow.right")
        }
        Button(role: .destructive) {
            withAnimation(reduceMotion ? nil : .snappy) {
                multiView.clear(tile: id, store: store)
            }
        } label: {
            Label("Remove from multi-view", systemImage: "xmark")
        }
    }

    // MARK: Actions

    /// The stored layout, and the channel it was opened with, if its source
    /// has room for it.
    private func start() {
        guard !didStart else { return }
        didStart = true
        if let stored = MultiViewArrangement(rawValue: arrangementRaw) {
            multiView.setArrangement(stored, store: store)
        }
        if let startingChannelKey,
           let channel = catalog.channel(ItemKey(rawValue: startingChannelKey)),
           let tile = multiView.firstEmptyVisibleTileID,
           MultiViewStart.canPlay(sourceID: channel.sourceID, states: multiView.streamStates(catalog: catalog, store: store)) {
            play(channel, inTile: tile)
        }
        focus = initialFocus
        lastFocus = focus
    }

    private func focusAfterPicking(tile id: Int) -> TVMultiViewFocus {
        TVMultiViewFocusRules.afterPicking(
            tile: id,
            slots: multiView.visibleTiles.map { .init(id: $0.id, isEmpty: $0.isEmpty) },
            hasRoomForAnother: multiView.streamStates(catalog: catalog, store: store).contains { !$0.isFull }
        )
    }

    private func perform(_ action: TVTileAction, on id: Int) {
        switch action {
        case .addChannel:
            picker = TVPickerRequest(tileID: id, isSwap: false)
        case .retry:
            guard let player = multiView.model.tiles.first(where: { $0.id == id })?.player else { return }
            Task { await player.retry() }
        case .giveSound:
            multiView.giveSound(toTile: id)
        case .fullScreen:
            multiView.expand(tile: id)
        }
    }

    private func play(_ channel: CatalogChannel, inTile id: Int) {
        let programme = catalog.nowAndNext(for: channel).now
        withAnimation(reduceMotion ? nil : .snappy) {
            multiView.play(channel, programme: programme, inTile: id, catalog: catalog, store: store, profileID: session.currentProfile?.id)
        }
    }

    private func setArrangement(_ arrangement: MultiViewArrangement) {
        withAnimation(reduceMotion ? nil : .snappy) {
            multiView.setArrangement(arrangement, store: store)
        }
        arrangementRaw = arrangement.rawValue
    }

    private func handleMenu() {
        switch TVMultiViewBack.onMenu(hasPicker: picker != nil, hasFullScreen: multiView.expanded != nil) {
        case .closePicker:
            picker = nil
        case .closeFullScreen:
            multiView.collapse()
        case .leave:
            multiView.closeAll(store: store)
            if let onClose { onClose() } else { dismiss() }
        }
    }
}
