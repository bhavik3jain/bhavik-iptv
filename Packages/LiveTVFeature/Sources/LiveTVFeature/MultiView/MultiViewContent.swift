import CatalogKit
import Core
import HouseholdKit
import PlayerKit
import SwiftUI

/// What the channel picker is filling.
private struct PickerRequest: Identifiable {
    var tileID: Int
    /// Swapping a playing tile: its own stream doesn't count against its
    /// source while picking.
    var isSwap: Bool
    var id: Int { tileID }
}

/// Multi-view (PLY-9, MAC-5; mockup 07): a bar with the layout buttons and
/// "Sound from …", the tiles sized to fill the space without scrolling, and
/// the now/next strip for the tile with the sound. A tap on a tile moves
/// the sound to it; its context menu takes it full screen, swaps or removes
/// it; an empty tile opens the channel picker, and says why when the
/// household's sources are at their stream limits. A channel dragged onto a
/// tile (an item key, as the Mac sidebar's favorites drag) plays there.
///
/// Leaving the screen closes every tile, so no stream is held for a screen
/// nobody sees.
struct MultiViewContent: View {
    /// The "Live TV  Guide | Multi-view" title, when nothing above draws it.
    let showsModePicker: Bool
    /// Guide was picked; nil dismisses the screen.
    let onShowGuide: (() -> Void)?

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("liveTV.multiView.arrangement") private var arrangementRaw = MultiViewArrangement.four.rawValue
    @State private var multiView = MultiViewSession()
    @State private var picker: PickerRequest?
    @State private var cache = GuideProgrammeCache()

    private static let spacing: CGFloat = 12

    var body: some View {
        TimelineView(.everyMinute) { context in
            GeometryReader { proxy in
                let isWide = proxy.size.width >= 720
                VStack(spacing: 0) {
                    controlBar(isWide: isWide)
                    Rectangle().fill(HearthColor.rowDivider).frame(height: 1).accessibilityHidden(true)
                    grid
                        .padding(.horizontal, isWide ? 20 : 16)
                        .padding(.top, 16)
                    strip(now: context.date, isWide: isWide)
                        .padding(.horizontal, isWide ? 20 : 16)
                        .padding(.vertical, 16)
                }
            }
        }
        .hearthScreenBackground()
        .sheet(item: $picker) { request in
            MultiViewChannelPicker(
                title: request.isSwap ? String(localized: "Change channel") : String(localized: "Add a channel"),
                states: streamStates(excludingTile: request.isSwap ? request.tileID : nil),
                onScreen: multiView.channelKeysOnScreen
            ) { channel in
                play(channel, inTile: request.tileID)
            }
        }
        .hearthFullScreenCover(item: expandedBinding) { expanded in
            PlayerView(model: expanded.player)
        }
        .task {
            // Who's-watching heartbeats and the Stalker watchdog while tiles
            // play; the session decides which are due.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MultiViewSession.keepAliveInterval))
                guard !Task.isCancelled else { return }
                await multiView.upkeep(now: .now, catalog: catalog, store: store)
            }
        }
        .onAppear {
            if let stored = MultiViewArrangement(rawValue: arrangementRaw) {
                multiView.setArrangement(stored, store: store)
            }
        }
        .onDisappear {
            // A tile taken full screen covers this screen (iOS reports that
            // as disappearing); its tiles keep playing for the way back.
            guard multiView.expanded == nil else { return }
            multiView.closeAll(store: store)
        }
        .onChange(of: session.currentProfile?.id) { _, _ in
            // A different profile mustn't inherit the last one's tiles (or
            // its who's-watching rows).
            multiView.closeAll(store: store)
        }
    }

    // MARK: Bar

    /// One row where it fits (the mockup's title bar); on a narrow screen
    /// the title and Guide | Multi-view keep the first row and the layout
    /// buttons and "Sound from …" move to a second.
    private func controlBar(isWide: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: isWide ? 16 : 8) {
                if showsModePicker { titleAndModes }
                arrangementButtons
                Spacer(minLength: 4)
                soundLabel
                AirPlayRouteButton()
            }
            .frame(minHeight: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if showsModePicker {
                        titleAndModes
                    } else {
                        arrangementButtons
                    }
                    Spacer(minLength: 4)
                    AirPlayRouteButton()
                }
                .frame(minHeight: 52)
                HStack(spacing: 8) {
                    if showsModePicker { arrangementButtons }
                    soundLabel
                    Spacer(minLength: 0)
                }
                .frame(minHeight: showsModePicker ? 44 : 0)
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, isWide ? 20 : 12)
    }

    @ViewBuilder
    private var titleAndModes: some View {
        Text("Live TV")
            .font(.hearthHeadline)
            .foregroundStyle(HearthColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .fixedSize()
        SegmentedPills(String(localized: "Live TV view"), options: LiveMode.allCases, selection: modeBinding, size: .compact) { $0.title }
            .fixedSize()
    }

    @ViewBuilder
    private var soundLabel: some View {
        if let name = multiView.model.audibleItemName {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Sound from \(name)")
                    .lineLimit(1)
            }
            .font(.hearthText(13, relativeTo: .footnote))
            .foregroundStyle(HearthColor.textSecondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var modeBinding: Binding<LiveMode> {
        Binding(get: { .multiView }, set: { mode in
            guard mode == .guide else { return }
            if let onShowGuide { onShowGuide() } else { dismiss() }
        })
    }

    /// One, side by side, grid of four, as the mockup's three glyphs.
    private var arrangementButtons: some View {
        HStack(spacing: 0) {
            ForEach(MultiViewArrangement.allCases) { arrangement in
                let isSelected = multiView.arrangement == arrangement
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        multiView.setArrangement(arrangement, store: store)
                    }
                    arrangementRaw = arrangement.rawValue
                } label: {
                    Image(systemName: arrangement.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? HearthColor.accent : HearthColor.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? HearthColor.selection : .clear)
                        )
                        .frame(width: HearthMetrics.minimumHitTarget - 6, height: HearthMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(arrangement.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
    }

    // MARK: Grid

    private var grid: some View {
        GeometryReader { proxy in
            let tiles = multiView.visibleTiles
            let geometry = MultiViewGridGeometry.make(tileCount: tiles.count, available: proxy.size, spacing: Self.spacing)
            let rows = stride(from: 0, to: tiles.count, by: max(geometry.columns, 1)).map { start in
                Array(tiles[start..<min(start + geometry.columns, tiles.count)])
            }
            VStack(spacing: Self.spacing) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: Self.spacing) {
                        ForEach(rows[index]) { tile in
                            tileView(tile)
                                .frame(width: geometry.tileSize.width, height: geometry.tileSize.height)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func tileView(_ tile: MultiViewModel.Tile) -> some View {
        if multiView.expanded?.tileID == tile.id {
            // The full-screen player has this tile's picture; one surface
            // can't be in two places.
            FullScreenPlaceholder(name: multiView.occupant(ofTile: tile.id)?.channel.name)
        } else if let player = tile.player {
            PlayerTileView(
                player: player,
                hasSound: tile.id == multiView.audibleTileID,
                sourceName: multiView.occupant(ofTile: tile.id).flatMap { SourceLabel.name(for: $0.channel, catalog: catalog) }
            ) {
                multiView.giveSound(toTile: tile.id)
            }
            .contextMenu { tileMenu(tile.id) }
            .accessibilityActions { tileMenu(tile.id) }
            .dropDestination(for: String.self) { keys, _ in drop(keys, onTile: tile.id) }
        } else {
            PlayerTileView(emptyReason: emptyTileReason) {
                picker = PickerRequest(tileID: tile.id, isSwap: false)
            }
            .dropDestination(for: String.self) { keys, _ in drop(keys, onTile: tile.id) }
        }
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
            picker = PickerRequest(tileID: id, isSwap: true)
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

    private var expandedBinding: Binding<MultiViewSession.Expanded?> {
        Binding(get: { multiView.expanded }, set: { value in
            if value == nil { multiView.collapse() }
        })
    }

    // MARK: Strip

    @ViewBuilder
    private func strip(now: Date, isWide: Bool) -> some View {
        if let occupant = multiView.audibleOccupant, let tileID = multiView.audibleTileID {
            let current = cache.nowAndNext(for: occupant.channel, catalog: catalog, revision: catalog.revision, now: now)
            let player = multiView.model.tiles.first(where: { $0.id == tileID })?.player
            NowNextStrip(
                channel: occupant.channel,
                now: current.now,
                next: current.next,
                date: now,
                isWide: isWide,
                canPlayFromStart: canPlayFromStart(player, current: current.now),
                onFromStart: {
                    guard let player else { return }
                    Task { await player.playFromStart() }
                },
                onFullScreen: { multiView.expand(tile: tileID) }
            )
        } else {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(HearthColor.glyphMuted)
                    .accessibilityHidden(true)
                Text("Add up to four channels. Tap a tile to hear it; touch and hold it for full screen.")
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous).fill(HearthColor.surface))
        }
    }

    /// From the start works on the tile's player when it was opened on the
    /// programme still on now (its item carries that programme's bounds).
    private func canPlayFromStart(_ player: PlayerModel?, current: CatalogProgramme?) -> Bool {
        guard let player, player.canPlayFromStart, let current else { return false }
        return player.item.programmeStart == current.start
    }

    // MARK: Actions

    private func play(_ channel: CatalogChannel, inTile id: Int) {
        let programme = catalog.nowAndNext(for: channel).now
        withAnimation(reduceMotion ? nil : .snappy) {
            multiView.play(channel, programme: programme, inTile: id, catalog: catalog, store: store, profileID: session.currentProfile?.id)
        }
    }

    private func drop(_ keys: [String], onTile id: Int) -> Bool {
        guard let raw = keys.first else { return false }
        let key = ItemKey(rawValue: raw)
        guard key.kind == .channel, let channel = catalog.channel(key) else { return false }
        play(channel, inTile: id)
        return true
    }

    // MARK: Stream limits

    /// Each source the profile can see, with its streams in use: other
    /// devices' who's-watching rows plus this screen's tiles.
    private func streamStates(excludingTile excluded: Int? = nil) -> [SourceStreamState] {
        let own = multiView.ownPlaybackIDs
        let visible = catalog.filter.visibleSourceIDs
        return catalog.sources
            .filter { visible?.contains($0.id) ?? true }
            .map { source in
                let record = store.sources.first { $0.id == source.id }
                let limit = SourceLimits.limit(
                    kindRaw: source.kind.rawValue,
                    maxStreams: record?.maxStreams ?? SourceLimits.defaultMaxStreams(kindRaw: source.kind.rawValue),
                    accountMaxConnections: catalog.account(sourceID: source.id)?.maxConnections
                )
                let others = store.streamUsage(sourceID: source.id, limit: limit).inUse.filter { !own.contains($0.id) }.count
                return SourceStreamState(
                    sourceID: source.id,
                    name: source.name,
                    inUse: others + multiView.tileCount(onSource: source.id, excludingTile: excluded),
                    limit: limit
                )
            }
    }

    private var emptyTileReason: String? {
        StreamLimitAdvice.emptyTileReason(streamStates())
    }
}

/// A tile while its picture is in the full-screen player.
private struct FullScreenPlaceholder: View {
    let name: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HearthColor.textSecondary)
            Text(name.map { String(localized: "\($0) is playing full screen") } ?? String(localized: "Playing full screen"))
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HearthColor.sidebar))
        .accessibilityElement(children: .combine)
    }
}

/// The strip under the tiles (mockup 07): NOW · 102 FIELDHOUSE SPORTS, the
/// programme and its progress between mono times; NEXT · 22:30 and its
/// length; From the start (an archive channel) and Full screen. Side by side
/// where there's room, stacked on a narrow screen.
private struct NowNextStrip: View {
    let channel: CatalogChannel
    let now: CatalogProgramme?
    let next: CatalogProgramme?
    let date: Date
    let isWide: Bool
    let canPlayFromStart: Bool
    let onFromStart: () -> Void
    let onFullScreen: () -> Void

    var body: some View {
        Group {
            if isWide {
                HStack(alignment: .center, spacing: 24) {
                    nowBlock.frame(maxWidth: .infinity, alignment: .leading)
                    if next != nil {
                        Rectangle().fill(HearthColor.hairline).frame(width: 1).padding(.vertical, 2).accessibilityHidden(true)
                        nextBlock.frame(maxWidth: 280, alignment: .leading)
                    }
                    buttons
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    nowBlock
                    if next != nil { nextBlock }
                    buttons
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous).fill(HearthColor.surface))
        .accessibilityElement(children: .contain)
    }

    private var numberedName: String {
        ChannelText.numberedName(number: channel.number, name: channel.name)
    }

    private var nowBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(String(localized: "Now · \(numberedName)"), style: .panel)
                .lineLimit(1)
            Text(now?.title ?? channel.name)
                .font(.hearthSectionTitle)
                .foregroundStyle(HearthColor.textPrimary)
                .lineLimit(2)
            if let now {
                HStack(spacing: 10) {
                    Text(verbatim: HearthFormat.clock(now.start))
                        .font(.hearthMono(12, relativeTo: .caption))
                        .foregroundStyle(HearthColor.textSecondary)
                    HearthProgressBar(value: now.progress(at: date), height: 4)
                        .frame(maxWidth: isWide ? 520 : .infinity)
                    Text(verbatim: HearthFormat.clock(now.end))
                        .font(.hearthMono(12, relativeTo: .caption))
                        .foregroundStyle(HearthColor.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(ProgrammeText.spokenCell(title: now.title, start: now.start, end: now.end, now: date, isPlayable: false)))
            } else {
                Text("No guide information")
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var nextBlock: some View {
        if let next {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(String(localized: "Next · \(HearthFormat.clock(next.start))"), style: .init(size: 11, color: HearthColor.textSecondary, isHeader: false))
                Text(next.title)
                    .font(.hearthText(15, weight: .medium, relativeTo: .body))
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(1)
                Text(verbatim: HearthFormat.duration(next.duration))
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if canPlayFromStart {
                Button(action: onFromStart) {
                    Text("From the start")
                }
                .buttonStyle(.hearthSecondary(shape: .rounded, size: .small))
                .accessibilityHint(Text("Plays the programme with the sound from its start"))
            }
            Button(action: onFullScreen) {
                Text("Full screen")
            }
            .buttonStyle(.hearthPrimary(shape: .rounded, size: .small))
            .accessibilityHint(Text("Shows the tile with the sound full screen"))
        }
        .fixedSize()
    }
}
