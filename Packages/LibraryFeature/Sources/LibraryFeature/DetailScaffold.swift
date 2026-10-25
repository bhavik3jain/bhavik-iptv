import Core
import SwiftUI

/// The frame both detail screens share (VOD-2, mockup 04), in two layouts:
///
/// - `.compact` (iPhone, the folded iPhone Duo): artwork runs edge to edge
///   behind the status and navigation bars and fades into the background, the
///   title and meta line sit on its lower edge, and everything else stacks
///   below.
/// - `.sidebar` (iPad, Mac, the opened iPhone Duo): the poster and the
///   metadata side by side over a blurred wash of the artwork, with the
///   full-width part (a show's seasons and episodes) underneath.
///
/// Only the artwork ignores the safe area; text and controls stay inside it,
/// and nothing assumes the left and right insets match (the opened Duo has
/// its status bar down one side).
struct DetailScaffold<Actions: View, Aside: View, Content: View>: View {
    let title: String
    let metaParts: [String]
    let artworkURL: URL?
    /// The main button row, right under the title.
    @ViewBuilder var actions: Actions
    /// Beside the poster in the sidebar layout, under the actions on a phone:
    /// the household card, the plot, the credits.
    @ViewBuilder var aside: Aside
    /// Full width at the foot: a show's seasons and episodes.
    @ViewBuilder var content: Content

    @Environment(\.hearthLayout) private var layout

    var body: some View {
        ScrollView {
            switch layout {
            case .compact: compactBody
            case .sidebar: sidebarBody
            }
        }
        .scrollRevealedTitle(title, threshold: layout == .compact ? 190 : 80)
        .hearthScreenBackground()
    }

    // MARK: Compact

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailTitleBlock(title: title, metaParts: metaParts, onArtwork: true)
                .padding(.horizontal, HearthMetrics.screenPadding)
                // Room for the artwork above the title, as in mockup 04; the
                // bars' height comes on top of this through the safe area.
                .padding(.top, 150)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .bottom) {
                    DetailBackdrop(url: artworkURL, title: title)
                        .ignoresSafeArea(edges: [.top, .horizontal])
                }
            VStack(alignment: .leading, spacing: 18) {
                actions
                aside
                content
            }
            .padding(.horizontal, HearthMetrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 36)
        }
    }

    // MARK: Sidebar

    private var sidebarBody: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 28) {
                ArtworkView(url: artworkURL, title: title, aspectRatio: 2.0 / 3.0, showsTitleOnPlaceholder: true)
                    .clipShape(RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous)
                            .strokeBorder(HearthColor.hairline, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                    // A third of the width, between a small-phone poster and
                    // one that would crowd the text on a wide Mac window.
                    .containerRelativeFrame(.horizontal) { length, _ in
                        min(max(length * 0.3, 128), 300)
                    }
                VStack(alignment: .leading, spacing: 18) {
                    DetailTitleBlock(title: title, metaParts: metaParts, onArtwork: false)
                    actions
                    aside
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
            content
                .frame(maxWidth: 980, alignment: .leading)
        }
        .padding(.horizontal, libraryGutter(.sidebar))
        .padding(.top, 20)
        .padding(.bottom, 40)
        .frame(maxWidth: libraryMaxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            DetailBackdrop(url: artworkURL, title: title, isWash: true)
                .frame(height: 460)
                .ignoresSafeArea()
        }
    }
}

/// The title in Sora and the meta line under it.
struct DetailTitleBlock: View {
    let title: String
    let metaParts: [String]
    /// Over artwork (the phone's hero) the meta line takes the lighter ink.
    let onArtwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.hearthDisplay(34, weight: .bold, relativeTo: .largeTitle))
                .tracking(-0.68)
                .foregroundStyle(HearthColor.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !metaParts.isEmpty {
                Text(MetaLine.joined(metaParts))
                    .font(.hearthFootnote)
                    .foregroundStyle(onArtwork ? HearthColor.textOnArtwork : HearthColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(MetaLine.spoken(metaParts)))
            }
        }
    }
}

/// The artwork behind a detail screen, fading into the background at its
/// foot (and darkened at its head so the bar's buttons stay legible). As a
/// wash it is blurred and dimmed: a poster blown up to a window's width is
/// a colour, not a picture. Decorative.
struct DetailBackdrop: View {
    let url: URL?
    let title: String
    var isWash = false

    var body: some View {
        Rectangle()
            .fill(HearthColor.hero)
            .overlay { TilePalette.color(for: title).opacity(isWash ? 0.25 : 0.4) }
            .overlay {
                if let url {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .blur(radius: isWash ? 40 : 0, opaque: true)
                                .opacity(isWash ? 0.5 : 1)
                        }
                    }
                }
            }
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: HearthColor.background.opacity(isWash ? 0.35 : 0), location: 0),
                        .init(color: HearthColor.background.opacity(isWash ? 0.6 : 0), location: 0.4),
                        .init(color: HearthColor.background, location: 0.96),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
            }
            .accessibilityHidden(true)
    }
}

/// A plot that opens to its full length on "More": long provider synopses
/// would push the episodes off the first screen.
struct ExpandableText: View {
    let text: String
    var collapsedLines = 4
    @State private var isExpanded = false

    /// Short enough to show whole without a "More".
    private var isShort: Bool { text.count <= collapsedLines * 70 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.hearthBody)
                .foregroundStyle(HearthColor.textPrimary.opacity(0.9))
                .lineSpacing(3)
                .lineLimit(isExpanded || isShort ? nil : collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !isShort {
                Button(isExpanded ? String(localized: "Less") : String(localized: "More")) {
                    withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
                }
                .font(.hearthText(14, weight: .semibold, relativeTo: .callout))
                .foregroundStyle(HearthColor.accent)
                .buttonStyle(.plain)
                .frame(minHeight: HearthMetrics.minimumHitTarget)
                .accessibilityLabel(Text(isExpanded ? "Show less of the plot" : "Show the whole plot"))
            }
        }
    }
}

/// A label and its value in a detail screen's credits: "CAST" over the names.
struct CreditRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(label, style: .card)
            Text(value)
                .font(.hearthCallout)
                .foregroundStyle(HearthColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The amber main button of a detail screen, filling the row's width.
struct DetailPlayButton: View {
    let title: String
    let spokenTitle: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.hearthPrimary)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(spokenTitle))
    }
}
