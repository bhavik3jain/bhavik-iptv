import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// Picks the channel for a multi-view tile on the Apple TV (PLY-9): full
/// screen, since a tvOS sheet is a narrow card, with the categories across
/// the top and a list the remote walks. Each limited source's streams show
/// up top (HH-5). A channel whose source is at its limit, or one already in a
/// tile, says so and does nothing when selected; it can still take focus,
/// because a run of disabled rows would stop the remote reaching the ones
/// below (a lazy list only has the rows near the screen).
///
/// Menu closes it. It always has something to focus (the search field, at
/// worst), or Menu would reach nothing.
struct TVMultiViewChannelPicker: View {
    let title: String
    /// Every source's streams, with the tile being swapped (if any) already
    /// left out.
    let states: [SourceStreamState]
    let onScreen: Set<ItemKey>
    let onCancel: () -> Void
    let onPick: (CatalogChannel) -> Void

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session

    @State private var query = ""
    @State private var chipID: String?
    @State private var chips: [LiveChip] = []
    @State private var chip: LiveChip = .all
    @State private var channels: [CatalogChannel] = []
    @State private var cache = GuideProgrammeCache()
    @State private var hasLoaded = false
    @FocusState private var focus: TVChannelPickerFocus?

    private var keepsFavorites: Bool { session.currentProfile != nil && !session.isGuest }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var statesByID: [UUID: SourceStreamState] {
        Dictionary(states.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            controls
                .hearthFocusSection()
            TimelineView(.everyMinute) { context in
                list(now: context.date)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .hearthScreenBackground()
        .defaultFocus($focus, initialFocus)
        .hearthOnExitCommand(onCancel)
        .task(id: LoadKey(query: query, chipID: chipID, revision: catalog.revision, storeRevision: store.revision)) {
            if !query.isEmpty {
                // A short pause so each change of the text doesn't run a fetch.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            reload()
        }
    }

    private var initialFocus: TVChannelPickerFocus {
        TVChannelPickerFocus.initial(
            channelKeys: channels.map(\.key.rawValue),
            firstAvailableKey: channels.first { availability(of: $0) == .available }?.key.rawValue
        )
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 40) {
            Text(title)
                .font(.hearthTVTitle)
                .tracking(-0.5)
                .foregroundStyle(HearthColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize()
            Spacer(minLength: 20)
            ForEach(states.filter { $0.limit != nil }) { state in
                let usage = StreamBarUsage(inUse: state.inUse, limit: state.limit)
                Text("\(state.name): \(usage.countText) streams")
                    .font(.hearthTVCallout)
                    .foregroundStyle(state.isFull ? HearthColor.accent : HearthColor.textSecondary)
                    .lineLimit(1)
                    .accessibilityLabel(Text("\(state.name), \(usage.spokenText)"))
            }
        }
    }

    /// The search field, then the categories (or, while searching, a way to
    /// clear it: the keyboard screen is one Select away but this is quicker).
    private var controls: some View {
        HStack(spacing: 20) {
            TextField("Channel name or number", text: $query)
                .focused($focus, equals: .search)
                .noAutocapitalization()
                .frame(width: 460)
            if isSearching {
                Button("Clear search") { query = "" }
                    .buttonStyle(.hearthTV)
                    .focused($focus, equals: .clearSearch)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(chips) { item in
                            Button(item.title) {
                                chipID = item.id
                            }
                            .buttonStyle(.hearthTV(isSelected: item == chip))
                            .focused($focus, equals: .chip(item.id))
                            .accessibilityAddTraits(item == chip ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Categories"))
            }
        }
    }

    @ViewBuilder
    private func list(now: Date) -> some View {
        if channels.isEmpty {
            if hasLoaded {
                TVNoticeCard(
                    systemName: isSearching ? "magnifyingglass" : "tv",
                    title: isSearching ? String(localized: "No channels match") : String(localized: "No channels here"),
                    message: isSearching ? String(localized: "Check the spelling, or try the channel's number.") : String(localized: "Try another category.")
                )
                .frame(maxWidth: 1200, alignment: .leading)
            }
            Spacer(minLength: 0)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 14) {
                    ForEach(channels) { channel in
                        row(channel, now: now)
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
    }

    private func row(_ channel: CatalogChannel, now: Date) -> some View {
        let availability = availability(of: channel)
        let current = cache.nowAndNext(for: channel, catalog: catalog, revision: catalog.revision, now: now).now
        return Button {
            if availability == .available { onPick(channel) }
        } label: {
            TVChannelPickerRow(
                channel: channel,
                now: current,
                date: now,
                sourceName: SourceLabel.name(for: channel, catalog: catalog),
                note: availability.note
            )
        }
        .buttonStyle(.hearthTVRow)
        .focused($focus, equals: .channel(channel.key.rawValue))
        .opacity(availability == .available ? 1 : 0.6)
        .accessibilityLabel(Text(ChannelText.numberedName(number: channel.number, name: channel.name)))
        .accessibilityValue(Text(availability.note ?? current?.title ?? ""))
        .accessibilityHint(availability == .available ? Text("Plays the channel in the tile") : Text(verbatim: ""))
    }

    // MARK: Logic

    private func availability(of channel: CatalogChannel) -> MultiViewChannelAvailability {
        MultiViewChannelAvailability.of(isOnScreen: onScreen.contains(channel.key), source: statesByID[channel.sourceID])
    }

    private func reload() {
        let favoriteKeys = keepsFavorites
            ? (session.currentProfile.map { store.favorites(profileID: $0.id, kind: .channel).map(\.itemKey) } ?? [])
            : []
        chips = LiveChip.chips(categories: catalog.categories(kind: .live), showsFavorites: keepsFavorites)
        chip = LiveChip.resolve(rememberedID: chipID, chips: chips, hasFavorites: !favoriteKeys.isEmpty)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        channels = trimmed.isEmpty
            ? ChipChannels.channels(for: chip, favoriteKeys: favoriteKeys, catalog: catalog)
            : catalog.findChannels(trimmed, includingWhatsOnAt: .now)
        let firstLoad = !hasLoaded
        hasLoaded = true
        if firstLoad { focus = initialFocus }
        // What had focus may have left the list (Clear search, a refresh).
        if let focus, !focus.isValid(channelKeys: Set(channels.map(\.key.rawValue)), chipIDs: Set(chips.map(\.id)), isSearching: isSearching) {
            self.focus = .search
        }
    }
}

/// A channel at ten feet: number, logo, name, source, what's on and how far
/// through it, or the note that says why it can't be picked.
private struct TVChannelPickerRow: View {
    let channel: CatalogChannel
    let now: CatalogProgramme?
    let date: Date
    let sourceName: String?
    let note: String?

    var body: some View {
        HStack(spacing: 24) {
            Text(verbatim: channel.number.map(String.init) ?? "")
                .font(.hearthTVMono)
                .foregroundStyle(HearthColor.textTertiary)
                .frame(minWidth: 72, alignment: .trailing)
            ChannelLogo(name: channel.name, url: channel.logoURL, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(channel.name)
                        .font(.hearthTVHeadline)
                        .foregroundStyle(HearthColor.textPrimary)
                    if let sourceName {
                        Text(sourceName)
                            .font(.hearthTVCaption)
                            .foregroundStyle(HearthColor.textTertiary)
                    }
                }
                Text(note ?? now?.title ?? String(localized: "No guide information"))
                    .font(.hearthTVCallout)
                    .foregroundStyle(note == nil ? HearthColor.textSecondary : HearthColor.accent)
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            if note == nil, let now {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(verbatim: HearthFormat.compactTimeRange(now.start, now.end))
                        .font(.hearthTVMono)
                        .foregroundStyle(HearthColor.textTertiary)
                    HearthProgressBar(value: now.progress(at: date), height: 6)
                        .frame(width: 240)
                }
            }
        }
    }
}

private struct LoadKey: Hashable {
    var query: String
    var chipID: String?
    var revision: Int
    var storeRevision: Int
}
