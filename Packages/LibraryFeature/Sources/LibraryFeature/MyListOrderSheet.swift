import Core
import HouseholdKit
import SwiftUI

/// Reorder My List (FAV-3): the profile's movies and shows in its own order,
/// dragged into place, as Live TV's Favorite channels sheet does for
/// channels. The order syncs through the household, so every device —
/// the Apple TV included — shows it.
///
/// It lists every title the profile may see, those still loading on this
/// device and those no longer offered included, so the order around them is
/// set too. Titles the profile's rules hide aren't listed (a Kids profile
/// shouldn't learn their names) and keep their places: a move is written by
/// the ids shown (`HouseholdStore.moveFavorites(…shownIDs:…)`), never by
/// offsets, which would be the store's list's and move the wrong row.
struct MyListOrderSheet: View {
    let profileID: UUID
    /// Each kind's entries in the profile's order (`MyListScreen.entries`).
    let movies: [MyListEntry]
    let shows: [MyListEntry]

    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !movies.isEmpty {
                    section(String(localized: "Movies", bundle: .module), rows: movies.map(MyListOrderRow.init), kind: .movie)
                }
                if !shows.isEmpty {
                    section(String(localized: "Shows", bundle: .module), rows: shows.map(MyListOrderRow.init), kind: .series)
                }
            }
            .hearthAlwaysReordering()
            .hearthScrollContentBackgroundHidden()
            .hearthScreenBackground()
            .overlay {
                if movies.isEmpty && shows.isEmpty {
                    EmptyStateView(systemName: "heart", title: String(localized: "Nothing in My List yet", bundle: .module))
                }
            }
            .navigationTitle(Text("Reorder My List", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                        .hearthDefaultActionShortcut()
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 480, maxWidth: .infinity, minHeight: 320, idealHeight: 640, maxHeight: .infinity)
    }

    private func section(_ title: String, rows: [MyListOrderRow], kind: FavoriteKind) -> some View {
        let ids = rows.map(\.id)
        return Section {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                OrderRowView(row: row)
                    .listRowBackground(HearthColor.surface)
                    .accessibilityActions {
                        if index > 0 {
                            Button(String(localized: "Move up", bundle: .module)) { move(kind, ids, from: index, to: index - 1) }
                        }
                        if index < rows.count - 1 {
                            Button(String(localized: "Move down", bundle: .module)) { move(kind, ids, from: index, to: index + 2) }
                        }
                        Button(String(localized: "Remove from My List", bundle: .module)) { remove(row.id, kind: kind) }
                    }
                    // The Mac has no swipe or edit mode: its moves to either
                    // end and its removal are here (a long list is a long
                    // drag).
                    .contextMenu {
                        if index > 0 {
                            Button {
                                move(kind, ids, from: index, to: 0)
                            } label: {
                                Label(String(localized: "Move to Top", bundle: .module), systemImage: "arrow.up.to.line")
                            }
                        }
                        if index < rows.count - 1 {
                            Button {
                                move(kind, ids, from: index, to: rows.count)
                            } label: {
                                Label(String(localized: "Move to Bottom", bundle: .module), systemImage: "arrow.down.to.line")
                            }
                        }
                        Button(role: .destructive) {
                            remove(row.id, kind: kind)
                        } label: {
                            Label(String(localized: "Remove from My List", bundle: .module), systemImage: "heart.slash")
                        }
                    }
            }
            .onMove { from, to in
                store.moveFavorites(profileID: profileID, kind: kind, shownIDs: ids, fromOffsets: from, toOffset: to)
            }
            .onDelete { offsets in
                for index in offsets where rows.indices.contains(index) {
                    remove(rows[index].id, kind: kind)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if kind == .series || shows.isEmpty {
                Text("Drag to set the order My List shows in, on every device in the household.", bundle: .module)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
            }
        }
    }

    private func move(_ kind: FavoriteKind, _ ids: [UUID], from: Int, to: Int) {
        store.moveFavorites(profileID: profileID, kind: kind, shownIDs: ids, fromOffsets: IndexSet(integer: from), toOffset: to)
    }

    private func remove(_ id: UUID, kind: FavoriteKind) {
        guard let favorite = (kind == .movie ? movies : shows).first(where: { $0.favorite.id == id })?.favorite else { return }
        store.toggleFavorite(profileID: profileID, itemKey: favorite.itemKey, kind: favorite.kind)
    }
}

/// A row of the sheet: a small poster, the title and what's known of it.
private struct OrderRowView: View {
    let row: MyListOrderRow

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: row.posterURL, title: row.title)
                .frame(width: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .saturation(row.state == .available ? 1 : 0)
                .opacity(row.state == .available ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.hearthBody)
                    .foregroundStyle(row.state == .available ? HearthColor.textPrimary : HearthColor.textTertiary)
                    .lineLimit(2)
                if let caption = row.caption {
                    Text(caption)
                        .font(.hearthCaption)
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            ReorderGrip()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
