import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// A titled shelf of posters. On the phone it is the mockup's sideways row;
/// in the sidebar layout (iPad, Mac, iPhone Duo open) it wraps into a grid,
/// since a wide screen of one sideways row hides most of it off the edge.
struct PosterShelf<Item: Identifiable, Tile: View>: View {
    let title: String
    let items: [Item]
    let layout: HearthLayout
    let gutter: CGFloat
    let contentWidth: CGFloat
    /// The grid stops after this many rows; nil shows everything.
    let maxRows: Int?
    @ViewBuilder let tile: (Item) -> Tile

    /// The mockup's 108-pt posters, growing with Dynamic Type because the
    /// placeholder carries the title.
    @ScaledMetric(relativeTo: .body) private var rowTileWidth: CGFloat = 108
    @ScaledMetric(relativeTo: .body) private var gridTileMinimum: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title)
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

/// A show in "Up next in your shows" (SER-2): the poster opens the show, the
/// line under it plays the episode that's next.
struct UpNextTile: View {
    let item: UpNextItem
    /// The profile whose progress the menu may change; nil for a Guest.
    let profileID: UUID?

    @Environment(HouseholdStore.self) private var store
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: HearthRoute.series(itemKey: item.seriesKey)) {
                PosterTile(title: item.seriesName, url: item.posterURL, badge: item.badge, progress: item.progress)
            }
            .buttonStyle(.hearthTile)
            .accessibilityHint(Text("Opens the show", bundle: .module))

            Button {
                play(item.playIntent)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(HearthColor.onAccent)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(HearthColor.accent))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(item.caption)
                        .font(.hearthCaption)
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, minHeight: HearthMetrics.minimumHitTarget, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hearthTile)
            .accessibilityLabel(Text("Play \(item.badge), \(item.caption)", bundle: .module))
        }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        Button {
            play(item.playIntent)
        } label: {
            Label(item.resumePosition == nil ? String(localized: "Play \(item.badge)", bundle: .module) : String(localized: "Resume \(item.badge)", bundle: .module), systemImage: "play.fill")
        }
        Button {
            openRoute(.series(itemKey: item.seriesKey))
        } label: {
            Label(String(localized: "Go to show", bundle: .module), systemImage: "info.circle")
        }
        if let profileID {
            Divider()
            // Marking it watched moves the shelf on to the episode after.
            Button {
                store.setWatched(true, profileID: profileID, itemKey: item.episodeKey)
            } label: {
                Label(String(localized: "Mark \(item.badge) as watched", bundle: .module), systemImage: "checkmark.circle")
            }
        }
    }
}

