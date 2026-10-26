import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// Find a channel by name or number (LIV-6). Results come from the catalog
/// as you type (it matches the number's start and every word of the name);
/// a tap plays the channel live with the results as the queue, the info
/// button opens its page, and Return plays the first result — type "101",
/// press Return, watch.
struct ChannelSearchSheet: View {
    let onPlay: (CatalogChannel, [CatalogChannel]) -> Void
    let onOpenChannel: (CatalogChannel) -> Void

    @Environment(CatalogService.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [CatalogChannel] = []
    @State private var cache = GuideProgrammeCache()
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                SearchField(String(localized: "Channel name or number"), text: $query, focus: $isFocused) {
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let first = results.first { play(first) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                TimelineView(.everyMinute) { context in
                    resultsList(now: context.date)
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
            results = catalog.findChannels(trimmed)
        }
        .onAppear { isFocused = true }
    }

    @ViewBuilder
    private func resultsList(now: Date) -> some View {
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
/// swipe or Delete to remove. Each move writes only the moved row
/// (`HouseholdStore.moveFavorites`), so a reorder syncs as one small change.
/// Favorites whose channel isn't in the catalog right now (a source
/// refreshing, a channel the profile can't see) stay in the list, so the
/// order around them is kept.
struct FavoritesOrderSheet: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(CatalogService.self) private var catalog
    @Environment(ProfileSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The store's queries aren't observable themselves: reading its
        // revision redraws the list after a move, a removal or a sync.
        let _ = store.revision
        let profileID = session.currentProfile?.id
        let favorites = profileID.map { store.favorites(profileID: $0, kind: .channel) } ?? []
        let channels = Dictionary(
            catalog.channels(keys: favorites.map { ItemKey(rawValue: $0.itemKey) }).map { ($0.key.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        NavigationStack {
            List {
                Section {
                    ForEach(Array(favorites.enumerated()), id: \.element.id) { index, favorite in
                        let channel = channels[favorite.itemKey]
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
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(HearthColor.glyphMuted)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(HearthColor.surface)
                        .accessibilityElement(children: .combine)
                        .accessibilityActions {
                            if index > 0 {
                                Button("Move up") { move(profileID, from: index, to: index - 1) }
                            }
                            if index < favorites.count - 1 {
                                Button("Move down") { move(profileID, from: index, to: index + 2) }
                            }
                            Button("Remove from favorites") { remove(profileID, favorite) }
                        }
                    }
                    .onMove { from, to in
                        guard let profileID else { return }
                        store.moveFavorites(profileID: profileID, kind: .channel, fromOffsets: from, toOffset: to)
                    }
                    .onDelete { offsets in
                        for index in offsets where favorites.indices.contains(index) {
                            remove(profileID, favorites[index])
                        }
                    }
                } footer: {
                    Text("Drag to set the order Favorites shows in Live TV and on Home.")
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .hearthScreenBackground()
            .overlay {
                if favorites.isEmpty {
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

    private func move(_ profileID: UUID?, from: Int, to: Int) {
        guard let profileID else { return }
        store.moveFavorites(profileID: profileID, kind: .channel, fromOffsets: IndexSet(integer: from), toOffset: to)
    }

    private func remove(_ profileID: UUID?, _ favorite: FavoriteRecord) {
        guard let profileID else { return }
        store.toggleFavorite(profileID: profileID, itemKey: favorite.itemKey, kind: .channel)
    }
}
