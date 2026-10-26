import CatalogKit
import Core
import SwiftUI

/// The round heart beside a programme or channel (FAV-1): amber and filled
/// when the channel is a favorite. Drawn like Core's `IconCircleButton`
/// (`.raised`), which keeps its glyph white; the mockup's heart is amber.
struct FavoriteHeartButton: View {
    let isFavorite: Bool
    var size: CGFloat = 44
    var fill: Color = HearthColor.surfaceRaised
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(isFavorite ? HearthColor.accent : HearthColor.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .frame(width: max(size, HearthMetrics.minimumHitTarget), height: max(size, HearthMetrics.minimumHitTarget))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isFavorite ? "Remove from favorites" : "Add to favorites"))
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }
}

/// A channel as a row (LIV-1): number, logo, name, and what's on now with
/// its progress. The channel list, search results and multi-view's picker
/// all draw this; the caller wraps it in a button.
struct ChannelNowRow: View {
    let channel: CatalogChannel
    let now: CatalogProgramme?
    let date: Date
    /// "Provider B", when the household has more than one source (SRC-7).
    var sourceName: String?
    /// A note in place of the programme ("At stream limit", "On screen").
    var note: String?
    var logoSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: channel.number.map(String.init) ?? "")
                .font(.hearthMono(12, relativeTo: .caption))
                .foregroundStyle(HearthColor.textSecondary)
                .frame(minWidth: 30, alignment: .trailing)
                .lineLimit(1)
                .accessibilityHidden(true)
            ChannelLogo(name: channel.name, url: channel.logoURL, size: logoSize)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(channel.name)
                        .font(.hearthText(15, weight: .medium, relativeTo: .body))
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                    if let sourceName {
                        Text(sourceName)
                            .font(.hearthCaption)
                            .foregroundStyle(HearthColor.textTertiary)
                            .lineLimit(1)
                    }
                }
                if let note {
                    Text(note)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textTertiary)
                        .lineLimit(1)
                } else if let now {
                    HStack(spacing: 6) {
                        Text(now.title)
                            .font(.hearthFootnote)
                            .foregroundStyle(HearthColor.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(verbatim: HearthFormat.compactTimeRange(now.start, now.end))
                            .font(.hearthMono(11, relativeTo: .caption2))
                            .foregroundStyle(HearthColor.textTertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    HearthProgressBar(value: now.progress(at: date), height: 3)
                        .accessibilityHidden(true)
                } else {
                    Text("No guide information")
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenText))
    }

    private var spokenText: String {
        var sentence = ChannelText.spokenNowPlaying(
            number: channel.number,
            name: channel.name,
            programme: now?.title,
            timing: now.map { ProgrammeTiming(start: $0.start, end: $0.end) },
            isLive: true,
            at: date
        )
        if let sourceName { sentence += ", " + sourceName }
        if let note { sentence += ". " + note }
        return sentence
    }
}

/// A short horizontal rule between rows, inset past the number column.
struct RowDivider: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(HearthColor.hairline)
            .frame(height: 1)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

/// The text of a source's name for labels, only when the household has more
/// than one source (SRC-7): one source needs no "from Provider B".
enum SourceLabel {
    @MainActor
    static func name(for channel: CatalogChannel, catalog: CatalogService) -> String? {
        catalog.sources.count > 1 ? channel.sourceName : nil
    }
}
