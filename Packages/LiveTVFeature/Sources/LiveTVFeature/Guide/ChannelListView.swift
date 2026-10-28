import CatalogKit
import Core
import SwiftUI

/// The simple channel list (LIV-1): number, logo, name, what's on now and
/// its progress. A tap plays the channel live with the chip's channels as
/// the queue (LIV-5); the info button opens the channel's page; a long press
/// offers From the start and the heart. Rows on a phone; cards in an
/// adaptive grid where there's width for more than one column.
struct ChannelListView: View {
    let channels: [CatalogChannel]
    let now: Date
    let revision: Int
    let cache: GuideProgrammeCache
    let shortGuides: ShortGuideRequests
    let showsFavorites: Bool
    let favoriteKeys: Set<String>
    let bottomInset: CGFloat
    let listID: String
    let onToggleFavorite: (CatalogChannel) -> Void
    let onAction: (ProgrammeAction, CatalogChannel, CatalogProgramme?) -> Void

    @Environment(CatalogService.self) private var catalog
    @Environment(\.hearthLayout) private var layout
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if usesGrid(width: proxy.size.width) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: HearthMetrics.itemSpacing)], spacing: HearthMetrics.itemSpacing) {
                        ForEach(channels) { channel in
                            row(channel)
                                .padding(.horizontal, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous)
                                        .fill(HearthColor.surface)
                                )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(channels) { channel in
                            row(channel)
                            RowDivider(leadingInset: 98)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .scrollPosition($position)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
        }
        .onChange(of: listID) { _, _ in position.scrollTo(edge: .top) }
    }

    private func usesGrid(width: CGFloat) -> Bool {
        layout == .sidebar && width >= 680
    }

    private func row(_ channel: CatalogChannel) -> some View {
        let nowNext = cache.nowAndNext(for: channel, catalog: catalog, revision: revision, now: now)
        let isFavorite = favoriteKeys.contains(channel.key.rawValue)
        return HStack(spacing: 4) {
            Button {
                onAction(.watchLive, channel, nowNext.now)
            } label: {
                ChannelNowRow(channel: channel, now: nowNext.now, date: now, sourceName: SourceLabel.name(for: channel, catalog: catalog))
            }
            .buttonStyle(.hearthTile)
            .accessibilityHint(Text("Plays the channel live"))

            if showsFavorites {
                Button {
                    onToggleFavorite(channel)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(isFavorite ? HearthColor.accent : HearthColor.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isFavorite ? "Remove \(channel.name) from favorites" : "Add \(channel.name) to favorites"))
                .sensoryFeedback(.selection, trigger: isFavorite)
            }

            NavigationLink(value: HearthRoute.channel(itemKey: channel.key.rawValue)) {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(HearthColor.textTertiary)
                    .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(channel.name) details"))
        }
        .contextMenu {
            Button {
                onAction(.watchLive, channel, nowNext.now)
            } label: {
                Label(ProgrammeAction.watchLive.title, systemImage: ProgrammeAction.watchLive.systemImage)
            }
            if channel.hasArchive, let current = nowNext.now {
                Button {
                    onAction(.fromTheStart, channel, current)
                } label: {
                    Label(ProgrammeAction.fromTheStart.title, systemImage: ProgrammeAction.fromTheStart.systemImage)
                }
            }
            if showsFavorites {
                Button {
                    onToggleFavorite(channel)
                } label: {
                    Label(isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: isFavorite ? "heart.slash" : "heart")
                }
            }
        }
        .accessibilityActions {
            if showsFavorites {
                Button(isFavorite ? "Remove from favorites" : "Add to favorites") { onToggleFavorite(channel) }
            }
            if channel.hasArchive, let current = nowNext.now {
                Button(ProgrammeAction.fromTheStart.title) { onAction(.fromTheStart, channel, current) }
            }
        }
        .onAppear { shortGuides.request(channel, catalog: catalog) }
    }
}
