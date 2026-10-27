import SwiftUI

// Home's cards (HOME-1): the Continue watching hero and a favorite channel's
// now-playing card. Sizes and colours from docs/handoff/ui/screens/Home.html.

/// The Continue watching hero: an eyebrow, the title in Sora Bold, a
/// subtitle ("S2 · E5 — The Lighthouse Keeper"), an amber Resume button and
/// the resume point as a bar with "31 min left".
///
/// Behind it sits the show's artwork under a scrim, or until that loads (and
/// for providers that send none) the mockup's decoration: a beam of amber
/// light over a dark hill on `tint`. The card grows with Dynamic Type rather
/// than clipping, and at accessibility sizes the button and progress stack.
public struct HeroCard: View {
    public var eyebrow: String?
    public var title: String
    public var subtitle: String?
    public var progress: Double?
    public var remainingText: String?
    public var artworkURL: URL?
    public var tint: Color
    public var actionTitle: String?
    public var action: () -> Void

    /// - Parameters:
    ///   - eyebrow: The small amber line; nil says "Continue watching".
    ///   - progress: The resume point, 0…1; nil hides the bar.
    ///   - remainingText: "31 min left" (`HearthFormat.remaining`).
    ///   - tint: The card colour behind the decoration.
    ///   - actionTitle: The button's title; nil says "Resume".
    public init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        progress: Double? = nil,
        remainingText: String? = nil,
        artworkURL: URL? = nil,
        tint: Color = HearthColor.hero,
        actionTitle: String? = nil,
        action: @escaping () -> Void
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.remainingText = remainingText
        self.artworkURL = artworkURL
        self.tint = tint
        self.actionTitle = actionTitle
        self.action = action
    }

    @ScaledMetric(relativeTo: .title) private var minHeight: CGFloat = 212
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(eyebrow ?? String(localized: "Continue watching", bundle: .module), style: .eyebrow)
                Text(title)
                    .font(.hearthDisplay(28, weight: .bold, relativeTo: .title))
                    .tracking(-0.56)
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.hearthText(14, relativeTo: .subheadline))
                        .foregroundStyle(HearthColor.textOnArtwork)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .accessibilityHidden(true)
                        Text(actionTitle ?? String(localized: "Resume", bundle: .module))
                    }
                }
                .buttonStyle(.hearthPrimary(shape: .capsule, size: .regular))
                .fixedSize()

                if progress != nil || remainingText != nil {
                    resumePoint
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .bottomLeading)
        .background { backdrop }
        .clipShape(RoundedRectangle(cornerRadius: HearthMetrics.heroRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var resumePoint: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress {
                HearthProgressBar(value: progress, height: 4, track: .overlay)
            }
            if let remainingText {
                Text(remainingText)
                    .font(.hearthCaption)
                    .foregroundStyle(HearthColor.textOnArtwork)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(remainingText ?? String(localized: "Progress", bundle: .module)))
        .accessibilityValue(progress.map { Text(min(max($0, 0), 1).formatted(.percent.precision(.fractionLength(0)))) } ?? Text(verbatim: ""))
    }

    private var backdrop: some View {
        ZStack {
            tint
            HeroDecoration()
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .overlay {
                                // Keeps the white title and the amber button
                                // legible over bright artwork.
                                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                            }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The hero's decoration from the mockup: an amber lamp on a dark post
/// throwing a soft beam, and a dark hill in the corner. Drawn in the SVG's
/// 210 × 212 space, scaled to the card's height and pinned to its trailing
/// edge, so it never sits under the text on a phone.
struct HeroDecoration: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.height / 212
            let originX = size.width + 10 * scale - 210 * scale
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: originX + x * scale, y: y * scale)
            }
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(origin: point(x, y), size: CGSize(width: width * scale, height: height * scale))
            }

            var beam = Path()
            beam.move(to: point(150, 40))
            beam.addLine(to: point(210, 10))
            beam.addLine(to: point(210, 90))
            beam.closeSubpath()
            context.fill(beam, with: .color(HearthColor.accent.opacity(0.22)))

            context.fill(Path(rect(138, 44, 22, 120)), with: .color(HearthColor.heroShade))
            context.fill(Path(roundedRect: rect(134, 36, 30, 14), cornerRadius: 3 * scale), with: .color(HearthColor.accent))

            var hill = Path()
            hill.move(to: point(120, 212))
            hill.addCurve(to: point(210, 204), control1: point(140, 182), control2: point(180, 182))
            hill.addLine(to: point(210, 212))
            hill.closeSubpath()
            context.fill(hill, with: .color(HearthColor.heroShade))
        }
    }
}

/// A favorite channel on Home: logo, number and name, LIVE, the programme on
/// air, its times in Plex Mono and how far through it is.
///
/// The bar and "min left" move on their own once a minute, so Home doesn't
/// have to re-render to keep them true. A plain view: Home wraps it in a
/// `Button` with `.buttonStyle(.hearthTile)` to start playback. VoiceOver
/// reads it as one sentence (`ChannelText.spokenNowPlaying`).
public struct ChannelNowCard: View {
    public var name: String
    public var number: Int?
    public var logoURL: URL?
    public var programmeTitle: String?
    public var timing: ProgrammeTiming?
    public var isLive: Bool

    public init(name: String, number: Int? = nil, logoURL: URL? = nil, programmeTitle: String? = nil, timing: ProgrammeTiming? = nil, isLive: Bool = true) {
        self.name = name
        self.number = number
        self.logoURL = logoURL
        self.programmeTitle = programmeTitle
        self.timing = timing
        self.isLive = isLive
    }

    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 164

    public var body: some View {
        TimelineView(.everyMinute) { context in
            card(at: context.date)
        }
    }

    private func card(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ChannelLogo(name: name, url: logoURL, size: 38)
                VStack(alignment: .leading, spacing: 0) {
                    if let number {
                        Text(verbatim: String(number))
                            .font(.hearthMono(11, relativeTo: .caption2))
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                    Text(name)
                        .font(.hearthText(13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if isLive { LiveBadge() }
                Text(programmeTitle ?? String(localized: "No guide", bundle: .module, comment: "A channel card when the source sends no programme guide"))
                    .font(.hearthText(14, weight: .medium, relativeTo: .callout))
                    .foregroundStyle(programmeTitle == nil ? HearthColor.textTertiary : HearthColor.textPrimary)
                    .lineLimit(1)
                if let timing {
                    Text(timing.timeRange)
                        .font(.hearthMono(11, relativeTo: .caption2))
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(1)
                }
            }
            if let timing {
                HearthProgressBar(value: timing.progress(at: now), height: 3)
            }
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous)
                .fill(HearthColor.surface)
        )
        .contentShape(RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ChannelText.spokenNowPlaying(number: number, name: name, programme: programmeTitle, timing: timing, isLive: isLive, at: now)))
    }
}

/// The press feedback for a card or tile wrapped in a button (a channel
/// card, a poster, a profile): it dims, and shrinks slightly unless Reduce
/// Motion is on. With focus (the Apple TV's remote, a keyboard elsewhere) it
/// grows a little and casts a shadow. Draws nothing else, so the card keeps
/// its own look.
public struct HearthTileButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HearthTileButtonBody(configuration: configuration)
    }
}

private struct HearthTileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(scale)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 16, y: 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
            .contentShape(Rectangle())
    }
}

private extension HearthTileButtonBody {
    var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if configuration.isPressed { return 0.97 }
        return isFocused ? 1.06 : 1
    }
}

extension ButtonStyle where Self == HearthTileButtonStyle {
    /// `.buttonStyle(.hearthTile)` on a button whose label is a card.
    public static var hearthTile: HearthTileButtonStyle { HearthTileButtonStyle() }
}
