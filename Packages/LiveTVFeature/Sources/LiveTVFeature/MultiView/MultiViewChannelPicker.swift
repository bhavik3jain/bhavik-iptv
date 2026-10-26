import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// Picks the channel for a multi-view tile (PLY-9): search by name or number,
/// or browse Favorites, All channels and the categories, as Live TV does.
/// Each limited source's streams show at the top (HH-5); a channel whose
/// source is at its limit says so and can't be picked, and one already in a
/// tile says "On screen".
struct MultiViewChannelPicker: View {
    let title: String
    /// Every source's streams, with the tile being swapped (if any) already
    /// left out.
    let states: [SourceStreamState]
    let onScreen: Set<ItemKey>
    let onPick: (CatalogChannel) -> Void

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var chipID: String?
    @State private var chips: [LiveChip] = []
    @State private var chip: LiveChip = .all
    @State private var channels: [CatalogChannel] = []
    @State private var cache = GuideProgrammeCache()
    @FocusState private var isSearchFocused: Bool

    private var keepsFavorites: Bool { session.currentProfile != nil && !session.isGuest }

    private var statesByID: [UUID: SourceStreamState] {
        Dictionary(states.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                SearchField(String(localized: "Channel name or number"), text: $query, focus: $isSearchFocused) {
                    if let first = channels.first(where: { availability(of: $0) == .available }) { pick(first) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                let limited = states.filter { $0.limit != nil }
                if !limited.isEmpty {
                    streamBars(limited)
                        .padding(.horizontal, 20)
                }

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chipRow
                }

                TimelineView(.everyMinute) { context in
                    list(now: context.date)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .hearthScreenBackground()
            .navigationTitle(Text(title))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 540, minHeight: 520, idealHeight: 680)
        .task(id: LoadKey(query: query, chipID: chipID, revision: catalog.revision, storeRevision: store.revision)) {
            if !query.isEmpty {
                // A short pause so each keystroke doesn't run a fetch.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            reload()
        }
    }

    // MARK: Parts

    private func streamBars(_ limited: [SourceStreamState]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                ForEach(limited) { state in
                    StreamBar(state.name, usage: StreamBarUsage(inUse: state.inUse, limit: state.limit), size: .compact)
                        .frame(minWidth: 140, maxWidth: 220)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
                ForEach(limited) { state in
                    StreamBar(state.name, usage: StreamBarUsage(inUse: state.inUse, limit: state.limit), size: .compact)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: HearthMetrics.controlRadius, style: .continuous).fill(HearthColor.surface))
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { item in
                    PillChip(item.title, isSelected: item == chip) {
                        chipID = item.id
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Categories"))
    }

    @ViewBuilder
    private func list(now: Date) -> some View {
        if channels.isEmpty {
            EmptyStateView(
                systemName: query.isEmpty ? "tv" : "magnifyingglass",
                title: query.isEmpty ? String(localized: "No channels here") : String(localized: "No channels match"),
                message: query.isEmpty ? nil : String(localized: "Check the spelling, or try the channel's number.")
            )
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(channels) { channel in
                        row(channel, now: now)
                        RowDivider(leadingInset: 98)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func row(_ channel: CatalogChannel, now: Date) -> some View {
        let availability = availability(of: channel)
        let current = cache.nowAndNext(for: channel, catalog: catalog, revision: catalog.revision, now: now).now
        return Button {
            pick(channel)
        } label: {
            ChannelNowRow(
                channel: channel,
                now: current,
                date: now,
                sourceName: SourceLabel.name(for: channel, catalog: catalog),
                note: availability.note
            )
        }
        .buttonStyle(.hearthTile)
        .disabled(availability != .available)
        .opacity(availability == .available ? 1 : 0.55)
        .accessibilityHint(availability == .available ? Text("Plays the channel in the tile") : Text(verbatim: ""))
    }

    // MARK: Logic

    private enum Availability: Equatable {
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
    }

    private func availability(of channel: CatalogChannel) -> Availability {
        if onScreen.contains(channel.key) { return .onScreen }
        if let state = statesByID[channel.sourceID], let note = StreamLimitAdvice.channelNote(state) {
            return .sourceFull(note)
        }
        return .available
    }

    private func pick(_ channel: CatalogChannel) {
        dismiss()
        onPick(channel)
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
            : catalog.findChannels(trimmed)
    }
}

private struct LoadKey: Hashable {
    var query: String
    var chipID: String?
    var revision: Int
    var storeRevision: Int
}
