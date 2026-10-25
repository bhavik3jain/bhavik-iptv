import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// Pieces the library's screens share: the in-content large title that hands
// over to the navigation bar once scrolled away, the square icon buttons
// beside a detail screen's Play, a poster cell with its caption, and the
// adaptive grid metrics for both layouts.

// MARK: - Titles

/// The screen title written in Sora in the content (the mockups' large
/// titles), with the navigation bar's inline title appearing only once it has
/// scrolled out of view, so the two never show at once.
struct ScrollRevealedTitle: ViewModifier {
    let title: String
    /// Scrolled past this many points, the bar shows the title.
    let threshold: CGFloat
    @State private var isRevealed = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > threshold
            } action: { _, revealed in
                isRevealed = revealed
            }
            .navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.hearthHeadline)
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                        .opacity(isRevealed ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: isRevealed)
                        .accessibilityHidden(!isRevealed)
                }
            }
    }
}

extension View {
    /// Apply to the `ScrollView` whose content starts with a large title.
    func scrollRevealedTitle(_ title: String, threshold: CGFloat = 44) -> some View {
        modifier(ScrollRevealedTitle(title: title, threshold: threshold))
    }
}

/// A grid screen's header: the large title and a trailing control.
struct LibraryTitleRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.hearthLargeTitle)
                .tracking(HearthMetrics.titleTracking)
                .foregroundStyle(HearthColor.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

// MARK: - Buttons

/// The 48-pt rounded square beside a detail screen's main button: the My List
/// heart, "Play from the beginning" (mockup 04's heart and download buttons).
struct SquareIconButton: View {
    let systemName: String
    let label: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isActive ? HearthColor.accent : HearthColor.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HearthColor.surfaceButton))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.hearthTile)
        .accessibilityLabel(Text(label))
    }
}

/// The My List heart for a movie or show (FAV-3). Hidden for Guests, whose
/// lists are never saved (PRF-5).
struct MyListHeartButton: View {
    let itemKey: ItemKey
    let kind: FavoriteKind
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session

    var body: some View {
        if let profile = session.currentProfile, !profile.isGuest {
            let _ = store.revision
            let isFavorite = store.isFavorite(profileID: profile.id, itemKey: itemKey.rawValue)
            SquareIconButton(
                systemName: isFavorite ? "heart.fill" : "heart",
                label: isFavorite ? String(localized: "In My List") : String(localized: "Add to My List"),
                isActive: isFavorite
            ) {
                store.toggleFavorite(profileID: profile.id, itemKey: itemKey.rawValue, kind: kind)
            }
            .accessibilityHint(Text(isFavorite ? "Removes it from My List" : "Keeps it in My List on every device"))
            .sensoryFeedback(.selection, trigger: isFavorite)
        }
    }
}

// MARK: - Grids

/// Column widths for poster grids: phone-sized posters in the compact layout,
/// a little larger in the sidebar layout (iPad, Mac, the opened iPhone Duo),
/// where the grid gains columns rather than giant posters. Scaled with Dynamic
/// Type so captions keep room at large sizes.
struct PosterGridMetrics {
    @ScaledMetric(relativeTo: .body) private var compactMinimum: CGFloat = 100
    @ScaledMetric(relativeTo: .body) private var sidebarMinimum: CGFloat = 124

    func columns(for layout: HearthLayout) -> [GridItem] {
        let minimum = layout == .sidebar ? sidebarMinimum : compactMinimum
        return [GridItem(.adaptive(minimum: minimum), spacing: HearthMetrics.itemSpacing, alignment: .top)]
    }
}

/// Side padding for a screen's content: the mockups' 24 on a phone, a little
/// more in the sidebar layout.
func libraryGutter(_ layout: HearthLayout) -> CGFloat {
    layout == .sidebar ? 28 : HearthMetrics.screenPadding
}

/// The widest a library screen's content runs on a large Mac window before it
/// centres: grids gain columns up to here; beyond it lines get too long.
let libraryMaxContentWidth: CGFloat = 1280

/// A poster with its caption underneath: the title, and the year (or another
/// short line). Provider artwork often lacks a legible title, so the grid
/// always names what it shows.
struct PosterCell: View {
    let title: String
    let url: URL?
    let caption: String?
    let decoration: PosterDecoration
    var isUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterTile(title: title, url: url, badge: decoration.badge, progress: decoration.progress)
                .saturation(isUnavailable ? 0 : 1)
                .opacity(isUnavailable ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.hearthText(13, weight: .medium, relativeTo: .footnote))
                    .foregroundStyle(isUnavailable ? HearthColor.textSecondary : HearthColor.textPrimary)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.hearthCaption)
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(spokenValue))
    }

    private var spokenValue: String {
        var parts: [String] = []
        if let caption { parts.append(caption) }
        if let badge = decoration.badge { parts.append(badge) }
        if let progress = decoration.progress {
            parts.append(String(localized: "\(progress.formatted(.percent.precision(.fractionLength(0)))) watched"))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - States

/// A centred progress spinner with a line under it, for first loads.
struct LibraryLoadingView: View {
    let message: String
    var progress: Double?

    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(HearthColor.accent)
                    .frame(maxWidth: 220)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(HearthColor.accent)
            }
            Text(message)
                .font(.hearthCallout)
                .foregroundStyle(HearthColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Episode and title helpers

extension CatalogEpisode {
    /// "S2 E5 · The Lighthouse Keeper", the player's subtitle.
    var playerSubtitle: String {
        let code = EpisodeCode.short(season: season, episode: number)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? code : "\(code) · \(trimmed)"
    }
}
