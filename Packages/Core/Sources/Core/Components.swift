import SwiftUI

// The shared building blocks of every screen in the mockups. Their initialisers
// are the contract the feature packages build against: change what they draw
// freely, change a signature only additively. Sizes, colours and type come
// from the mockups' HTML (docs/handoff/ui/screens); the components added with
// the design system pass live in the Components+*.swift files beside this one.

/// A profile's square avatar: a colour plus a letter or SF Symbol (PRF-1).
/// The letter is sized to the tile, not to Dynamic Type, because the tile is
/// a picture of the profile rather than text to read.
public struct AvatarTile: View {
    public var name: String
    public var palette: AvatarPalette
    public var symbol: String?
    public var size: CGFloat
    /// Whether the profile asks for a PIN (PRF-3). Spoken by VoiceOver; the
    /// lock glyph itself sits beside the name (see `ProfileTile`).
    public var isLocked: Bool

    public init(name: String, palette: AvatarPalette, symbol: String? = nil, size: CGFloat = 96, isLocked: Bool = false) {
        self.name = name
        self.palette = palette
        self.symbol = symbol
        self.size = size
        self.isLocked = isLocked
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(palette.fill)
            .frame(width: size, height: size)
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(palette.ink)
                } else {
                    Text(Monogram.initials(for: name, maxLetters: 1))
                        .font(.hearth(.display, fixedSize: size * 0.44, weight: .bold))
                        .foregroundStyle(palette.ink)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(isLocked ? String(localized: "\(name), locked with a PIN", bundle: .module) : name))
    }
}

/// A channel's logo, or a monogram tile in a stable colour when there is no
/// logo or it fails to load (LIV-7).
public struct ChannelLogo: View {
    public var name: String
    public var url: URL?
    public var size: CGFloat

    public init(name: String, url: URL?, size: CGFloat = 44) {
        self.name = name
        self.url = url
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            shape.fill(TilePalette.color(for: name))
            Text(Monogram.initials(for: name, maxLetters: 2))
                .font(.hearth(.display, fixedSize: size * 0.34, weight: .bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(size * 0.08)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(size * 0.12)
                            .frame(width: size, height: size)
                            .background(HearthColor.surfaceRaised)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// A capsule filter chip: category pickers, "Favorites / All channels / News".
/// Drawn 36 pt tall as in the guide mockup, with the touch area padded to 44.
public struct PillChip: View {
    public var title: String
    public var isSelected: Bool
    public var action: () -> Void

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hearthText(14, weight: isSelected ? .semibold : .medium, relativeTo: .callout))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(isSelected ? HearthColor.onAccent : HearthColor.textPrimary)
                .background(Capsule().fill(isSelected ? HearthColor.accent : Color.clear))
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : HearthColor.stroke, lineWidth: 1))
                .padding(.vertical, (HearthMetrics.minimumHitTarget - 36) / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A thin amber-on-track progress bar (programme progress, resume points).
public struct HearthProgressBar: View {
    /// What the bar's empty part is drawn on.
    public enum Track: Sendable {
        /// A card or the screen background: `HearthColor.track`.
        case surface
        /// Artwork or video: translucent white.
        case overlay
    }

    public var value: Double
    public var height: CGFloat
    public var track: Track

    public init(value: Double, height: CGFloat = 4) {
        self.init(value: value, height: height, track: .surface)
    }

    public init(value: Double, height: CGFloat = 4, track: Track) {
        self.value = value
        self.height = height
        self.track = track
    }

    private var clamped: Double { min(max(value, 0), 1) }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track == .surface ? HearthColor.track : HearthColor.overlayTrack)
                Capsule().fill(HearthColor.accent)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress", bundle: .module))
        .accessibilityValue(Text(clamped.formatted(.percent.precision(.fractionLength(0)))))
    }
}

/// A round icon button (search, AirPlay, close, guide toggles). Always
/// labelled for VoiceOver, and never smaller than 44 pt to touch.
public struct IconCircleButton: View {
    /// What the button sits on, which decides its fill.
    public enum Style: Sendable {
        /// The screen background (Home's and Live TV's headers).
        case surface
        /// A card or sheet (the guide sheet's favorite button).
        case raised
        /// Video (the player's controls).
        case overlay
        /// Artwork (a show's back and share buttons).
        case scrim
    }

    public var systemName: String
    public var label: String
    public var size: CGFloat
    public var style: Style
    public var action: () -> Void

    public init(systemName: String, label: String, size: CGFloat = 44, action: @escaping () -> Void) {
        self.init(systemName: systemName, label: label, size: size, style: .surface, action: action)
    }

    public init(systemName: String, label: String, size: CGFloat = 44, style: Style, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.size = size
        self.style = style
        self.action = action
    }

    private var fill: Color {
        switch style {
        case .surface: HearthColor.surface
        case .raised: HearthColor.surfaceRaised
        case .overlay: HearthColor.overlayControl
        case .scrim: HearthColor.background.opacity(0.6)
        }
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(style == .overlay ? Color.white : HearthColor.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .frame(width: max(size, HearthMetrics.minimumHitTarget), height: max(size, HearthMetrics.minimumHitTarget))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// "● LIVE" in amber, small caps as on Home's channel cards.
public struct LiveBadge: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(HearthColor.accent).frame(width: 6, height: 6)
            Text("LIVE", bundle: .module)
                .font(.hearthText(10, weight: .semibold, relativeTo: .caption2))
                .tracking(0.8)
                .foregroundStyle(HearthColor.accent)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Live", bundle: .module))
    }
}

/// A screen section's title row with an optional trailing control
/// ("Favorite channels … Guide").
public struct SectionHeader<Trailing: View>: View {
    public var title: String
    public var trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.hearthSectionTitle)
                .foregroundStyle(HearthColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
                .font(.hearthText(14, relativeTo: .callout))
                .foregroundStyle(HearthColor.accent)
                .frame(minHeight: HearthMetrics.minimumHitTarget)
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    public init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A poster or episode still, with a stable colour placeholder while it loads
/// or when the provider sends none.
public struct ArtworkView: View {
    public var url: URL?
    public var title: String
    public var aspectRatio: CGFloat
    /// Writes the title on the placeholder, as the Home mockup's posters do;
    /// the loaded image covers it, since real artwork carries its own title.
    public var showsTitleOnPlaceholder: Bool

    /// `aspectRatio` is width / height: 2/3 for posters, 16/9 for stills.
    public init(url: URL?, title: String, aspectRatio: CGFloat = 2.0 / 3.0) {
        self.init(url: url, title: title, aspectRatio: aspectRatio, showsTitleOnPlaceholder: false)
    }

    public init(url: URL?, title: String, aspectRatio: CGFloat = 2.0 / 3.0, showsTitleOnPlaceholder: Bool) {
        self.url = url
        self.title = title
        self.aspectRatio = aspectRatio
        self.showsTitleOnPlaceholder = showsTitleOnPlaceholder
    }

    public var body: some View {
        Rectangle()
            .fill(TilePalette.color(for: title))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                if showsTitleOnPlaceholder {
                    Text(title)
                        .font(.hearthDisplay(15, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .padding(10)
                }
            }
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        }
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// A poster tile as on Home's "Up next in your shows": the title written on
/// the placeholder until the artwork loads, an optional badge ("S1 E7",
/// "New · S3 E3") and an optional progress bar.
public struct PosterTile: View {
    public var title: String
    public var url: URL?
    public var badge: String?
    public var progress: Double?

    public init(title: String, url: URL?, badge: String? = nil, progress: Double? = nil) {
        self.title = title
        self.url = url
        self.badge = badge
        self.progress = progress
    }

    public var body: some View {
        ArtworkView(url: url, title: title, showsTitleOnPlaceholder: true)
            .clipShape(RoundedRectangle(cornerRadius: HearthMetrics.tileRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let badge {
                    Text(badge)
                        .font(.hearthText(10, weight: .semibold, relativeTo: .caption2))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 20)
                        .background(Capsule().fill(HearthColor.badgeScrim))
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress {
                    HearthProgressBar(value: progress, height: 3, track: .overlay).padding(10)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text([title, badge].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityValue(progress.map { Text(min(max($0, 0), 1).formatted(.percent.precision(.fractionLength(0)))) } ?? Text(verbatim: ""))
    }
}

/// A full-width empty or error state with an optional action.
public struct EmptyStateView: View {
    public var systemName: String
    public var title: String
    public var message: String?
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(systemName: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemName = systemName
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(HearthColor.textSecondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(HearthColor.surface))
                .accessibilityHidden(true)
            Text(title)
                .font(.hearthDisplay(20, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(HearthColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.hearthText(15, relativeTo: .body))
                    .foregroundStyle(HearthColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.hearthPrimary)
                    .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// The shape of a Hearth button: a capsule (the hero's Resume) or a rounded
/// rectangle (detail screens, sheets, the Mac).
public enum HearthButtonShape: Sendable {
    case capsule
    case rounded
}

/// The size of a Hearth button, from the mockups.
public enum HearthButtonSize: Sendable {
    /// 48 pt, 16 pt type: a detail screen's main action ("Resume S2 E5").
    case large
    /// 44 pt, 15 pt type: cards and sheets ("Resume", "Watch live").
    case regular
    /// 36 pt, 13 pt type: the Mac's panels and the player's pills ("Full
    /// screen", "Jump to live"). The touch area is still padded to 44.
    case small

    var minHeight: CGFloat {
        switch self {
        case .large: 48
        case .regular: 44
        case .small: 36
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .large: 16
        case .regular: 15
        case .small: 13
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .large: 20
        case .regular: 18
        case .small: 14
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .large: 14
        case .regular: HearthMetrics.controlRadius
        case .small: 10
        }
    }
}

/// The body both button styles share: shape, size, pressed and disabled.
private struct HearthButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: HearthButtonShape
    let size: HearthButtonSize
    let fill: Color
    let foreground: Color
    let weight: Font.Weight
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let outline = shape == .capsule
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
        configuration.label
            .font(.hearthText(size.fontSize, weight: weight, relativeTo: .body))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.minHeight)
            .foregroundStyle(foreground)
            .background(outline.fill(fill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .padding(.vertical, max(0, (HearthMetrics.minimumHitTarget - size.minHeight) / 2))
            .contentShape(Rectangle())
    }
}

/// The amber button: "Resume", "Watch live", "Full screen".
public struct HearthPrimaryButtonStyle: ButtonStyle {
    public var shape: HearthButtonShape
    public var size: HearthButtonSize

    /// A large rounded button, as a detail screen's main action.
    public init() {
        self.init(shape: .rounded, size: .large)
    }

    public init(shape: HearthButtonShape, size: HearthButtonSize) {
        self.shape = shape
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        HearthButtonBody(configuration: configuration, shape: shape, size: size,
                         fill: HearthColor.accent, foreground: HearthColor.onAccent, weight: .semibold)
    }
}

/// The dark raised button beside a primary one ("From the start", "Remind
/// me").
public struct HearthSecondaryButtonStyle: ButtonStyle {
    public var shape: HearthButtonShape
    public var size: HearthButtonSize

    /// A large rounded button, to sit beside `HearthPrimaryButtonStyle()`.
    public init() {
        self.init(shape: .rounded, size: .large)
    }

    public init(shape: HearthButtonShape, size: HearthButtonSize) {
        self.shape = shape
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        HearthButtonBody(configuration: configuration, shape: shape, size: size,
                         fill: HearthColor.surfaceRaised, foreground: HearthColor.textPrimary, weight: .medium)
    }
}

extension ButtonStyle where Self == HearthPrimaryButtonStyle {
    public static var hearthPrimary: HearthPrimaryButtonStyle { HearthPrimaryButtonStyle() }

    /// `.buttonStyle(.hearthPrimary(shape: .capsule, size: .regular))`.
    public static func hearthPrimary(shape: HearthButtonShape, size: HearthButtonSize) -> HearthPrimaryButtonStyle {
        HearthPrimaryButtonStyle(shape: shape, size: size)
    }
}

extension ButtonStyle where Self == HearthSecondaryButtonStyle {
    public static var hearthSecondary: HearthSecondaryButtonStyle { HearthSecondaryButtonStyle() }

    /// `.buttonStyle(.hearthSecondary(shape: .rounded, size: .regular))`.
    public static func hearthSecondary(shape: HearthButtonShape, size: HearthButtonSize) -> HearthSecondaryButtonStyle {
        HearthSecondaryButtonStyle(shape: shape, size: size)
    }
}

extension View {
    /// The rounded dark card every grouped section sits on, with the faint
    /// outline the profile gate's household card has.
    public func hearthCard(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous)
                    .fill(HearthColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous)
                    .strokeBorder(HearthColor.hairline, lineWidth: 1)
            )
    }

    /// The app background behind a whole screen, edge to edge.
    public func hearthScreenBackground() -> some View {
        self.background(HearthColor.background.ignoresSafeArea())
    }
}

/// Initials for monogram tiles: "Cityline News" → "CN", "Bhavik" → "B".
public enum Monogram {
    public static func initials(for name: String, maxLetters: Int) -> String {
        let words = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "?" }
        let letters = words.prefix(maxLetters).compactMap { $0.first }
        return String(letters).uppercased()
    }
}
