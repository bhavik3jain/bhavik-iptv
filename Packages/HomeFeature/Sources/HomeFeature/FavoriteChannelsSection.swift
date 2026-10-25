import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// "Favorite channels" (HOME-1, mockup 02): the profile's favorites as
/// now-playing cards, synced across the household's devices. A card plays the
/// channel live, with the favorites as the channel up/down list; its menu
/// unfavorites it or opens the channel's page. Logos fall back to monogram
/// tiles (LIV-7, inside `ChannelNowCard`).
struct FavoriteChannelsSection: View {
    let channels: [CatalogChannel]
    /// Passed so a guide landing (which bumps it) redraws the cards' now
    /// playing even when the favorites themselves didn't change.
    let catalogRevision: Int
    let gutter: CGFloat
    /// The profile whose favorites the menu may change; nil for a Guest.
    let profileID: UUID?
    let isGuest: Bool
    let syncStatus: HouseholdSyncStatus

    /// The row stops here and hands over to the guide, which lists them all.
    static let rowLimit = 40

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, gutter)
            if channels.isEmpty {
                FavoritesHintCard(isGuest: isGuest)
                    .padding(.horizontal, gutter)
            } else {
                row
            }
        }
    }

    // MARK: Header

    /// `SectionHeader`'s look, with the sync chip beside the title as in the
    /// mockup (SectionHeader only has a trailing slot).
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Favorite channels", bundle: .module)
                .font(.hearthSectionTitle)
                .foregroundStyle(HearthColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if !isGuest, !channels.isEmpty, let chip = SyncChipContent.make(syncStatus) {
                StatusChip(chip.title, systemImage: chip.systemImage)
            }
            Spacer(minLength: 8)
            NavigationLink(value: HearthRoute.liveGuide) {
                Text("Guide", bundle: .module)
                    .font(.hearthText(14, relativeTo: .callout))
                    .foregroundStyle(HearthColor.accent)
                    .frame(minWidth: HearthMetrics.minimumHitTarget, minHeight: HearthMetrics.minimumHitTarget, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Open the guide", bundle: .module))
        }
    }

    // MARK: Row

    private var row: some View {
        let shown = Array(channels.prefix(Self.rowLimit))
        let queue = channels.map(\.key.rawValue)
        // Once a minute the programme on air may have changed; the cards'
        // own bars move between these on their own.
        return TimelineView(.everyMinute) { context in
            // Read here so a guide landing re-runs this closure (and its
            // now-playing lookups) without resetting the row's scroll.
            let _ = catalogRevision
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: HearthMetrics.itemSpacing) {
                    ForEach(shown) { channel in
                        card(for: channel, queue: queue, at: context.date)
                    }
                    if channels.count > shown.count {
                        MoreInGuideCard(hiddenCount: channels.count - shown.count)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, gutter, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private func card(for channel: CatalogChannel, queue: [String], at date: Date) -> some View {
        let now = catalog.nowAndNext(for: channel, at: date).now
        return Button {
            play(PlayIntent(
                itemKey: channel.key.rawValue,
                kind: .live,
                title: channel.name,
                subtitle: now?.title,
                artworkURL: channel.logoURL,
                queue: queue
            ))
        } label: {
            ChannelNowCard(
                name: channel.name,
                number: channel.number,
                logoURL: channel.logoURL,
                programmeTitle: now?.title,
                timing: now.map { ProgrammeTiming(start: $0.start, end: $0.end) },
                isLive: true
            )
            // A card without a guide is shorter; the same fill behind keeps
            // the row's cards one height.
            .frame(maxHeight: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous)
                    .fill(HearthColor.surface)
            )
        }
        .buttonStyle(.hearthTile)
        .contextMenu { menu(for: channel) }
        .accessibilityHint(Text("Plays the channel", bundle: .module))
        .accessibilityAction(named: Text("Open channel", bundle: .module)) {
            openRoute(.channel(itemKey: channel.key.rawValue))
        }
    }

    @ViewBuilder
    private func menu(for channel: CatalogChannel) -> some View {
        Button {
            openRoute(.channel(itemKey: channel.key.rawValue))
        } label: {
            Label(String(localized: "Open channel", bundle: .module), systemImage: "tv")
        }
        if let profileID {
            Button(role: .destructive) {
                store.toggleFavorite(profileID: profileID, itemKey: channel.key.rawValue, kind: .channel)
            } label: {
                Label(String(localized: "Unfavorite", bundle: .module), systemImage: "heart.slash")
            }
        }
    }
}

/// In place of the row when there are no favorites: what the row is for and
/// the way to the guide, where channels are favorited.
private struct FavoritesHintCard: View {
    let isGuest: Bool

    var body: some View {
        NavigationLink(value: HearthRoute.liveGuide) {
            HStack(spacing: 14) {
                Image(systemName: isGuest ? "tv" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(HearthColor.accent)
                    .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                    .background(Circle().fill(HearthColor.surfaceRaised))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.hearthHeadline)
                        .foregroundStyle(HearthColor.textPrimary)
                    Text(message)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HearthColor.glyphMuted)
                    .accessibilityHidden(true)
            }
            .hearthCard(padding: 16)
            .contentShape(RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.hearthTile)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the guide", bundle: .module))
    }

    private var title: String {
        isGuest
            ? String(localized: "Browse live TV", bundle: .module)
            : String(localized: "Pin your favorite channels", bundle: .module)
    }

    private var message: String {
        isGuest
            ? String(localized: "Guest profiles don't keep favorites. Open the guide to see what's on now.", bundle: .module)
            : String(localized: "Tap the heart on a channel in the guide and it shows up here with what's on.", bundle: .module)
    }
}

/// The end of a long favorites row: the rest are in the guide.
private struct MoreInGuideCard: View {
    let hiddenCount: Int

    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 120

    var body: some View {
        NavigationLink(value: HearthRoute.liveGuide) {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(HearthColor.accent)
                    .accessibilityHidden(true)
                Text("\(hiddenCount) more in the guide", bundle: .module)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous)
                    .fill(HearthColor.surface)
            )
            .contentShape(RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous))
        }
        .buttonStyle(.hearthTile)
    }
}
