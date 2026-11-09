import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// A titled shelf of posters with "See all". On the phone it is the mockup's
/// sideways row; in the sidebar layout (iPad, Mac, iPhone Duo open) it wraps
/// into a grid, since a wide screen of one sideways row hides most of it off
/// the edge.
struct PosterShelf<Item: Identifiable, Tile: View>: View {
    let title: String
    let items: [Item]
    let layout: HearthLayout
    let gutter: CGFloat
    let contentWidth: CGFloat
    /// The grid stops after this many rows; nil shows everything.
    let maxRows: Int?
    /// Where "See all" goes; nil for no link.
    let seeAll: HearthRoute?
    @ViewBuilder let tile: (Item) -> Tile

    /// The mockup's 108-pt posters, growing with Dynamic Type because the
    /// placeholder carries the title.
    @ScaledMetric(relativeTo: .body) private var rowTileWidth: CGFloat = 108
    @ScaledMetric(relativeTo: .body) private var gridTileMinimum: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title) {
                if let seeAll { SeeAllLink(route: seeAll) }
            }
            .padding(.horizontal, gutter)
            if layout == .sidebar {
                grid
            } else {
                row
            }
        }
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: HearthMetrics.itemSpacing) {
                ForEach(items) { item in
                    tile(item)
                        .frame(width: rowTileWidth)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, gutter, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }

    private var grid: some View {
        let spacing = HearthMetrics.itemSpacing
        let width = max(contentWidth - gutter * 2, 0)
        let columns = PosterGridFit.columns(width: width, minimum: gridTileMinimum, spacing: spacing)
        let count = maxRows.map { PosterGridFit.visibleCount(total: items.count, columns: columns, rows: $0) } ?? items.count
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columns),
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(items.prefix(count)) { item in
                tile(item)
            }
        }
        .padding(.horizontal, gutter)
    }
}

/// A section's "See all", to the tab that lists everything (Live TV, My
/// List). The visible words stay the label, for Voice Control; the hint says
/// where it goes.
struct SeeAllLink: View {
    let route: HearthRoute

    var body: some View {
        NavigationLink(value: route) {
            Text("See all", bundle: .module)
                .font(.hearthText(14, relativeTo: .callout))
                .foregroundStyle(HearthColor.accent)
                .frame(minWidth: HearthMetrics.minimumHitTarget, minHeight: HearthMetrics.minimumHitTarget, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(hint))
    }

    private var hint: String {
        switch route {
        case .liveGuide: String(localized: "Opens Live TV", bundle: .module)
        case .myList: String(localized: "Opens My List", bundle: .module)
        default: ""
        }
    }
}

/// A movie or show on a My List shelf: the poster and its name open the
/// title's page; the menu plays a movie or takes it off My List.
struct HomePosterTile: View {
    let poster: HomePoster
    /// The profile whose My List the menu may change; nil for a Guest.
    let profileID: UUID?

    @Environment(HouseholdStore.self) private var store
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        NavigationLink(value: poster.route) {
            VStack(alignment: .leading, spacing: 6) {
                PosterTile(title: poster.title, url: poster.posterURL, badge: poster.badge, progress: poster.progress)
                VStack(alignment: .leading, spacing: 1) {
                    Text(poster.title)
                        .font(.hearthText(13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                    if let caption = poster.caption {
                        Text(caption)
                            .font(.hearthCaption)
                            .foregroundStyle(HearthColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
            // One element inside the link, so it keeps the link's action.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(poster.title))
            .accessibilityValue(Text(spokenValue))
        }
        .buttonStyle(.hearthTile)
        .accessibilityHint(Text(poster.kind == .movie ? String(localized: "Opens the movie", bundle: .module) : String(localized: "Opens the show", bundle: .module)))
        .contextMenu { menu }
    }

    /// "2019, 25% watched", "S2 E5".
    private var spokenValue: String {
        var parts = [poster.caption, poster.badge].compactMap { $0 }
        if let progress = poster.progress {
            parts.append(String(localized: "\(progress.formatted(.percent.precision(.fractionLength(0)))) watched", bundle: .module))
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var menu: some View {
        if poster.kind == .movie {
            Button {
                play(PlayIntent(itemKey: poster.itemKey, kind: .movie, title: poster.title, artworkURL: poster.posterURL, startPosition: poster.resumePosition))
            } label: {
                Label(poster.resumePosition == nil ? String(localized: "Play", bundle: .module) : String(localized: "Resume", bundle: .module), systemImage: "play.fill")
            }
        }
        Button {
            openRoute(poster.route)
        } label: {
            Label(poster.kind == .movie ? String(localized: "Movie details", bundle: .module) : String(localized: "Go to show", bundle: .module), systemImage: "info.circle")
        }
        if let profileID {
            Divider()
            Button(role: .destructive) {
                store.toggleFavorite(profileID: profileID, itemKey: poster.itemKey, kind: poster.favoriteKind)
            } label: {
                Label(String(localized: "Remove from My List", bundle: .module), systemImage: "heart.slash")
            }
        }
    }
}
