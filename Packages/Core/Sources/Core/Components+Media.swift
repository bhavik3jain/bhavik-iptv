import SwiftUI

// Pieces of the guide, the player and a show's episode list: the amber
// now-line marker (docs/handoff/ui/screens/LiveGuide.html), the mono time
// badge ("−4:12", Player.html) and an episode row (ShowDetail.html).

/// A time in Plex Mono on a small rounded badge: the player's "−4:12"
/// behind live (PLY-5), or a programme length on a card. Information, not a
/// control, so it has no touch target of its own.
public struct TimeBadge: View {
    /// What the badge sits on, which decides its fill and ink.
    public enum Style: Sendable {
        /// Video or artwork: translucent white behind white text, as in the
        /// player.
        case overlay
        /// A card or the background: a raised surface behind grey text.
        case surface
        /// Amber behind dark text, for a time that is the point of the
        /// screen (the guide's now marker uses its own capsule).
        case accent
    }

    public var text: String
    public var spokenText: String?
    public var style: Style

    /// - Parameters:
    ///   - text: As shown: "−4:12", "48 min".
    ///   - spokenText: What VoiceOver says instead, when the text would be
    ///     misread ("4:12" sounds like a time of day). Defaults to `text`.
    public init(_ text: String, spokenText: String? = nil, style: Style = .overlay) {
        self.text = text
        self.spokenText = spokenText
        self.style = style
    }

    /// How far behind live a paused or rewound channel is (PLY-5): "−4:12",
    /// spoken "4 minutes, 12 seconds behind live". Pass a positive number of
    /// seconds.
    public init(behindLive seconds: TimeInterval, style: Style = .overlay) {
        self.init(
            HearthFormat.displayTimecode(-abs(seconds), signed: true),
            spokenText: String(localized: "\(HearthFormat.spokenDuration(seconds)) behind live", bundle: .module,
                               comment: "VoiceOver for the player's badge, e.g. 4 minutes, 12 seconds behind live"),
            style: style
        )
    }

    private var fill: Color {
        switch style {
        case .overlay: Color.white.opacity(0.16)
        case .surface: HearthColor.surfaceRaised
        case .accent: HearthColor.accent
        }
    }

    private var ink: Color {
        switch style {
        case .overlay: Color.white
        case .surface: HearthColor.textSecondary
        case .accent: HearthColor.onAccent
        }
    }

    public var body: some View {
        Text(verbatim: text)
            .font(.hearthMono(12, weight: .medium, relativeTo: .caption))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
            .accessibilityElement()
            .accessibilityLabel(Text(spokenText ?? text))
    }
}

/// The guide's now line (LIV-2): an amber capsule with the time ("20:42")
/// over a 2 pt amber line running down through the programme rows.
///
/// The marker is centred on its line, so `.position(x:)` (or an offset of
/// half its width) puts the line exactly at the current time. With no
/// `lineHeight` the line fills the height it is offered, which in an overlay
/// on the guide grid is the grid's height. The guide owns the clock (a
/// `TimelineView` that also moves the marker), so this view takes the time
/// rather than reading it.
public struct NowLineMarker: View {
    public var date: Date
    public var lineHeight: CGFloat?

    /// The line's width.
    public static let lineWidth: CGFloat = 2

    /// - Parameter lineHeight: The line's length under the capsule; nil
    ///   fills the space offered. 0 draws the capsule alone (the time
    ///   header of a guide that draws its own line).
    public init(_ date: Date, lineHeight: CGFloat? = nil) {
        self.date = date
        self.lineHeight = lineHeight
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: HearthFormat.clock(date))
                .font(.hearthMono(11, weight: .medium, relativeTo: .caption2))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(HearthColor.onAccent)
                .padding(.horizontal, 6)
                .frame(minHeight: 20)
                .background(Capsule().fill(HearthColor.accent))
                .fixedSize()
            if lineHeight != 0 {
                Rectangle()
                    .fill(HearthColor.accent)
                    .frame(width: Self.lineWidth)
                    .frame(height: lineHeight)
                    .frame(maxHeight: lineHeight == nil ? .infinity : nil)
                    // The capsule overlaps the top of the line, as in the
                    // mockup, so the two read as one mark.
                    .padding(.top, -2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Now, \(HearthFormat.clock(date))", bundle: .module,
                                 comment: "VoiceOver for the guide's now line, e.g. Now, 20:42"))
    }
}

/// An episode in a season's list: the still (with the resume point along its
/// foot), "5. The Lighthouse Keeper", "51 min · 31 min left", and a
/// checkmark once watched (SER-1).
///
/// A plain view, read by VoiceOver as one element: the show screen wraps it
/// in a `Button` with `.buttonStyle(.hearthTile)` to play the episode. At
/// accessibility text sizes the still moves above the text so the title
/// keeps the full width.
public struct EpisodeRow: View {
    public var number: Int?
    public var title: String
    public var stillURL: URL?
    public var duration: TimeInterval?
    public var remaining: TimeInterval?
    public var progress: Double?
    public var isWatched: Bool
    public var isDownloaded: Bool
    public var detail: String?

    /// - Parameters:
    ///   - number: The episode number, written before the title ("5.").
    ///   - remaining: Time left from the resume point; shown as "31 min
    ///     left" when the episode is started but not finished.
    ///   - progress: The resume point, 0…1, drawn along the still's foot; a
    ///     watched episode passes 1.
    ///   - detail: Replaces the generated "51 min · 31 min left" line.
    public init(
        number: Int? = nil,
        title: String,
        stillURL: URL? = nil,
        duration: TimeInterval? = nil,
        remaining: TimeInterval? = nil,
        progress: Double? = nil,
        isWatched: Bool = false,
        isDownloaded: Bool = false,
        detail: String? = nil
    ) {
        self.number = number
        self.title = title
        self.stillURL = stillURL
        self.duration = duration
        self.remaining = remaining
        self.progress = progress
        self.isWatched = isWatched
        self.isDownloaded = isDownloaded
        self.detail = detail
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var displayTitle: String { EpisodeText.title(number: number, title: title) }

    private var detailParts: [String] {
        if let detail { return [detail] }
        return EpisodeText.detailParts(duration: duration, remaining: isWatched ? nil : remaining, isDownloaded: isDownloaded)
    }

    public var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            still
                .frame(width: stacked ? nil : 128)
                .frame(maxWidth: stacked ? .infinity : nil)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.hearthText(15, weight: .medium, relativeTo: .body))
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(stacked ? nil : 2)
                    if !detailParts.isEmpty {
                        Text(detailParts.joined(separator: " · "))
                            .font(.hearthCaption)
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isWatched {
                    WatchedCheckmark()
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(displayTitle))
        .accessibilityValue(Text(spokenValue))
    }

    /// "51 min, 31 min left, watched": the detail line with commas, since
    /// VoiceOver reads "·" aloud as "dot" with some voices.
    private var spokenValue: String {
        var parts = detailParts
        if isWatched {
            parts.append(String(localized: "Watched", bundle: .module))
        }
        return parts.joined(separator: ", ")
    }

    private var still: some View {
        ArtworkView(url: stillURL, title: title, aspectRatio: 16.0 / 9.0)
            .overlay(alignment: .bottom) {
                if let progress, progress > 0 {
                    // Square ends along the foot of the still, clipped by its
                    // corners, as in the mockup.
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.5))
                            Rectangle().fill(HearthColor.accent)
                                .frame(width: proxy.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HearthMetrics.stillRadius, style: .continuous))
    }
}

/// The watched mark from the episode list: an amber check on a dark disc.
/// Decorative inside `EpisodeRow`, whose value says "Watched".
struct WatchedCheckmark: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 24
            context.fill(Path(ellipseIn: CGRect(x: 2 * unit, y: 2 * unit, width: 20 * unit, height: 20 * unit)),
                         with: .color(HearthColor.selection))
            var check = Path()
            check.move(to: CGPoint(x: 7.5 * unit, y: 12.5 * unit))
            check.addLine(to: CGPoint(x: 10.5 * unit, y: 15.5 * unit))
            check.addLine(to: CGPoint(x: 16.5 * unit, y: 9 * unit))
            context.stroke(check, with: .color(HearthColor.accent),
                           style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
