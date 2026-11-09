import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// Find a channel by name or number (LIV-6). Results come from the catalog
/// as you type (it matches the number's start and every word of the name);
/// a tap plays the channel live with the results as the queue, the heart
/// favorites it where it stands, the info button opens its page, and Return
/// plays the first result — type "101", press Return, watch.
struct ChannelSearchSheet: View {
    let onPlay: (CatalogChannel, [CatalogChannel]) -> Void
    let onOpenChannel: (CatalogChannel) -> Void

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [CatalogChannel] = []
    @State private var cache = GuideProgrammeCache()
    @FocusState private var isFocused: Bool

    var body: some View {
        let favorites = ChannelFavorites(store: store, profile: session.currentProfile)
        NavigationStack {
            VStack(spacing: 12) {
                SearchField(String(localized: "Channel name or number"), text: $query, focus: $isFocused) {
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let first = results.first { play(first) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                TimelineView(.everyMinute) { context in
                    resultsList(now: context.date, favorites: favorites)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .hearthScreenBackground()
            .navigationTitle(Text("Find a channel"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .liveSheetFrame(idealWidth: 520, idealHeight: 640)
        .task(id: SearchKeyID(query: query, revision: catalog.revision)) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty field lists nothing, so Return can't play a channel
            // nobody asked for.
            guard !trimmed.isEmpty else {
                results = []
                return
            }
            // A short pause so each keystroke doesn't run a fetch.
            if !results.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            results = catalog.findChannels(trimmed, includingWhatsOnAt: .now)
        }
        .onAppear { isFocused = true }
    }

    @ViewBuilder
    private func resultsList(now: Date, favorites: ChannelFavorites) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyStateView(
                systemName: "number",
                title: String(localized: "Type a name or a number"),
                message: String(localized: "\"News\" finds every news channel; \"101\" jumps to channel 101.")
            )
            Spacer(minLength: 0)
        } else if results.isEmpty {
            EmptyStateView(
                systemName: "magnifyingglass",
                title: String(localized: "No channels match"),
                message: String(localized: "Check the spelling, or try the channel's number.")
            )
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { channel in
                        let current = cache.nowAndNext(for: channel, catalog: catalog, revision: catalog.revision, now: now).now
                        HStack(spacing: 4) {
                            Button {
                                play(channel)
                            } label: {
                                ChannelNowRow(channel: channel, now: current, date: now, sourceName: SourceLabel.name(for: channel, catalog: catalog))
                            }
                            .buttonStyle(.hearthTile)
                            .accessibilityHint(Text("Plays the channel live"))

                            if favorites.canChange {
                                ChannelHeartButton(channelName: channel.name, isFavorite: favorites.contains(channel.key.rawValue)) {
                                    favorites.toggle(channel.key.rawValue)
                                }
                            }

                            Button {
                                dismiss()
                                onOpenChannel(channel)
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(HearthColor.textTertiary)
                                    .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("\(channel.name) details"))
                        }
                        RowDivider(leadingInset: 98)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func play(_ channel: CatalogChannel) {
        let queue = results
        dismiss()
        onPlay(channel, queue)
    }
}

private struct SearchKeyID: Hashable {
    var query: String
    var revision: Int
}

/// Favorite channels in the profile's own order (FAV-1): drag to reorder,
/// remove with Delete or a row's menu. Each move writes only the moved row
/// (`HouseholdStore.moveFavorites`), so a reorder syncs as one small change,
/// and every device, the Apple TV included, shows the new order.
/// Favorites whose channel isn't in the catalog right now (a source
/// refreshing, a channel gone from the provider) stay in the list, so the
/// order around them is kept; channels the profile's rules hide are left
/// off and keep their places (`FavoriteChannelRow`).
struct FavoritesOrderSheet: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(CatalogService.self) private var catalog
    @Environment(ProfileSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The store's queries aren't observable themselves: reading its
        // revision redraws the list after a move, a removal or a sync.
        let _ = (store.revision, catalog.revision)
        let profileID = session.currentProfile?.id
        let favorites = profileID.map { store.favorites(profileID: $0, kind: .channel) } ?? []
        let visible = Dictionary(
            catalog.channels(keys: favorites.map { ItemKey(rawValue: $0.itemKey) }).map { ($0.key.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = FavoriteChannelRow.rows(favorites: favorites, visible: visible) { catalog.contains(ItemKey(rawValue: $0)) }
        let ids = rows.map(\.id)
        NavigationStack {
            List {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let channel = row.channel
                        HStack(spacing: 12) {
                            ChannelLogo(name: channel?.name ?? "?", url: channel?.logoURL, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel?.name ?? String(localized: "Unavailable channel"))
                                    .font(.hearthBody)
                                    .foregroundStyle(channel == nil ? HearthColor.textTertiary : HearthColor.textPrimary)
                                if let number = channel?.number {
                                    Text(verbatim: String(number))
                                        .font(.hearthMono(11, relativeTo: .caption2))
                                        .foregroundStyle(HearthColor.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                            ReorderGrip()
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(HearthColor.surface)
                        .accessibilityElement(children: .combine)
                        .accessibilityActions {
                            if index > 0 {
                                Button("Move up") { move(profileID, ids, from: index, to: index - 1) }
                            }
                            if index < rows.count - 1 {
                                Button("Move down") { move(profileID, ids, from: index, to: index + 2) }
                            }
                            Button("Remove from favorites") { remove(profileID, row.favorite) }
                        }
                        // The Mac has no swipe or edit mode: its moves to
                        // either end and its removal are here.
                        .contextMenu {
                            if index > 0 {
                                Button {
                                    move(profileID, ids, from: index, to: 0)
                                } label: {
                                    Label("Move to Top", systemImage: "arrow.up.to.line")
                                }
                            }
                            if index < rows.count - 1 {
                                Button {
                                    move(profileID, ids, from: index, to: rows.count)
                                } label: {
                                    Label("Move to Bottom", systemImage: "arrow.down.to.line")
                                }
                            }
                            Button(role: .destructive) {
                                remove(profileID, row.favorite)
                            } label: {
                                Label("Remove from favorites", systemImage: "heart.slash")
                            }
                        }
                    }
                    .onMove { from, to in
                        guard let profileID else { return }
                        store.moveFavorites(profileID: profileID, kind: .channel, shownIDs: ids, fromOffsets: from, toOffset: to)
                    }
                    .onDelete { offsets in
                        for index in offsets where rows.indices.contains(index) {
                            remove(profileID, rows[index].favorite)
                        }
                    }
                } footer: {
                    Text("Drag to set the order your favorite channels show in, on every device in the household.")
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                }
            }
            .hearthAlwaysReordering()
            .hearthScrollContentBackgroundHidden()
            .hearthScreenBackground()
            .overlay {
                if rows.isEmpty {
                    EmptyStateView(systemName: "heart", title: String(localized: "No favorite channels yet"))
                }
            }
            .navigationTitle(Text("Favorite channels"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .liveSheetFrame(idealWidth: 480, idealHeight: 600)
    }

    private func move(_ profileID: UUID?, _ ids: [UUID], from: Int, to: Int) {
        guard let profileID else { return }
        store.moveFavorites(profileID: profileID, kind: .channel, shownIDs: ids, fromOffsets: IndexSet(integer: from), toOffset: to)
    }

    private func remove(_ profileID: UUID?, _ favorite: FavoriteRecord) {
        guard let profileID else { return }
        store.toggleFavorite(profileID: profileID, itemKey: favorite.itemKey, kind: .channel)
    }
}
