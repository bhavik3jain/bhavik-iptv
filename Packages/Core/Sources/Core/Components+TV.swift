import SwiftUI

// The pieces the features' `.tv` variants are drawn with (HearthLayout.tv):
// type and spacing for a screen across the room, a button style that answers
// focus rather than touch, shelves that scroll sideways under the screen's
// edge, and cards that lift with focus (the system card style on the TV).
// Nothing here is TV-only API, so it all builds everywhere; the few tvOS
// calls go through the shims in MacCompat.

// MARK: - Type and spacing

extension Font {
    /// A screen's title ("Who's watching?", a movie's name): Sora 60.
    public static var hearthTVLargeTitle: Font { .hearthDisplay(60, weight: .semibold, relativeTo: .largeTitle) }
    /// Sora 46.
    public static var hearthTVTitle: Font { .hearthDisplay(46, weight: .semibold, relativeTo: .title) }
    /// A shelf's title ("Favorite channels"): Sora 34.
    public static var hearthTVSectionTitle: Font { .hearthDisplay(34, weight: .semibold, relativeTo: .title3) }
    /// IBM Plex Sans 29 semibold, tvOS's headline size.
    public static var hearthTVHeadline: Font { .hearthText(29, weight: .semibold, relativeTo: .headline) }
    /// IBM Plex Sans 29, tvOS's body size.
    public static var hearthTVBody: Font { .hearthText(29, relativeTo: .body) }
    /// IBM Plex Sans 25.
    public static var hearthTVCallout: Font { .hearthText(25, relativeTo: .callout) }
    /// IBM Plex Sans 22: captions under cards, badges.
    public static var hearthTVCaption: Font { .hearthText(22, relativeTo: .caption) }
    /// IBM Plex Mono 22: channel numbers and times.
    public static var hearthTVMono: Font { .hearthMono(22, relativeTo: .caption) }
}

public enum HearthTVMetrics {
    /// The screen's side margin. tvOS's own safe area is 80 pt each side;
    /// shelves start there and scroll on under the edge.
    public static let gutter: CGFloat = 80
    /// Between one shelf and the next.
    public static let shelfSpacing: CGFloat = 64
    /// Between cards in a shelf or grid: room for the focused one to grow.
    public static let cardSpacing: CGFloat = 48
    /// A 2:3 poster: six across a 1920-pt screen.
    public static let posterWidth: CGFloat = 248
    /// A 16:9 still or channel card: four across.
    public static let landscapeWidth: CGFloat = 400
    public static let cardRadius: CGFloat = 16
    /// The height of a text button or pill.
    public static let buttonHeight: CGFloat = 66
}

// MARK: - Buttons

/// A text button or pill on the TV: a raised surface at rest; white with dark
/// ink, a little larger and lifted, when focused — tvOS's own convention, so
/// focus is never mistaken for anything else. Amber stays Hearth's mark:
/// `isProminent` is the screen's main action (Play), amber at rest;
/// `isSelected` is the current choice in a row (a category), amber text.
public struct HearthTVButtonStyle: ButtonStyle {
    public var isProminent: Bool
    public var isSelected: Bool

    public init(isProminent: Bool = false, isSelected: Bool = false) {
        self.isProminent = isProminent
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        HearthTVButtonLabel(configuration: configuration, isProminent: isProminent, isSelected: isSelected)
    }
}

private struct HearthTVButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let isProminent: Bool
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.hearthText(27, weight: .semibold, relativeTo: .body))
            .lineLimit(1)
            .padding(.horizontal, 32)
            .frame(minHeight: HearthTVMetrics.buttonHeight)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(scale)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if configuration.isPressed { return 1.02 }
        return isFocused ? 1.08 : 1
    }

    private var foreground: Color {
        if isFocused { return HearthColor.background }
        if isProminent { return HearthColor.onAccent }
        return isSelected ? HearthColor.accent : HearthColor.textPrimary
    }

    private var fill: Color {
        if isFocused { return HearthColor.textPrimary }
        if isProminent { return HearthColor.accent }
        return isSelected ? HearthColor.surfaceRaised : HearthColor.surfaceButton
    }
}

extension ButtonStyle where Self == HearthTVButtonStyle {
    /// `.buttonStyle(.hearthTV)`: a text button for the TV.
    public static var hearthTV: HearthTVButtonStyle { HearthTVButtonStyle() }

    /// The screen's main action, or the current choice in a row.
    public static func hearthTV(isProminent: Bool = false, isSelected: Bool = false) -> HearthTVButtonStyle {
        HearthTVButtonStyle(isProminent: isProminent, isSelected: isSelected)
    }
}

/// A row of a list on the TV (a setting, a source, a person): full width,
/// the surface colour at rest, raised and outlined in amber when focused.
public struct HearthTVRowButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HearthTVRowLabel(configuration: configuration)
    }
}

private struct HearthTVRowLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.hearthTVBody)
            .foregroundStyle(HearthColor.textPrimary)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HearthTVMetrics.cardRadius, style: .continuous)
                    .fill(isFocused ? HearthColor.surfaceRaised : HearthColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HearthTVMetrics.cardRadius, style: .continuous)
                    .strokeBorder(HearthColor.accent, lineWidth: isFocused ? 4 : 0)
            )
            .scaleEffect(isFocused && !reduceMotion ? 1.02 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
    }
}

extension ButtonStyle where Self == HearthTVRowButtonStyle {
    /// `.buttonStyle(.hearthTVRow)`: a list row for the TV.
    public static var hearthTVRow: HearthTVRowButtonStyle { HearthTVRowButtonStyle() }
}

// MARK: - Shelves and cards

/// A titled row that scrolls sideways: Home's shelves, a show's seasons.
/// The cards keep drawing past the screen's edge (as tvOS rows do) and the
/// row is one focus section, so a swipe down from a short row above lands in
/// it rather than skipping it.
public struct TVShelf<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String?
    let spacing: CGFloat
    let content: Content
    let accessory: Accessory

    public init(_ title: String, subtitle: String? = nil, spacing: CGFloat = HearthTVMetrics.cardSpacing, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.spacing = spacing
        self.content = content()
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(title)
                    .font(.hearthTVSectionTitle)
                    .tracking(-0.4)
                    .foregroundStyle(HearthColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.hearthTVCallout)
                        .foregroundStyle(HearthColor.textSecondary)
                }
                Spacer(minLength: 0)
                accessory
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    content
                }
                // Room above and below for the focused card's lift.
                .padding(.vertical, 28)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .hearthFocusSection()
    }
}

extension TVShelf where Accessory == EmptyView {
    public init(_ title: String, subtitle: String? = nil, spacing: CGFloat = HearthTVMetrics.cardSpacing, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, spacing: spacing, content: content) { EmptyView() }
    }
}

/// A card the focus engine lifts: the artwork in the system card on the TV,
/// a title and caption below it that brighten while it has focus. Either
/// opens a route (`NavigationLink`) or runs an action.
public struct TVCard<Artwork: View>: View {
    private enum Target {
        case route(HearthRoute)
        case action(() -> Void)
    }

    private let target: Target
    private let width: CGFloat
    private let title: String?
    private let caption: String?
    private let artwork: Artwork
    @FocusState private var isFocused: Bool

    public init(route: HearthRoute, width: CGFloat, title: String? = nil, caption: String? = nil, @ViewBuilder artwork: () -> Artwork) {
        self.target = .route(route)
        self.width = width
        self.title = title
        self.caption = caption
        self.artwork = artwork()
    }

    public init(width: CGFloat, title: String? = nil, caption: String? = nil, action: @escaping () -> Void, @ViewBuilder artwork: () -> Artwork) {
        self.target = .action(action)
        self.width = width
        self.title = title
        self.caption = caption
        self.artwork = artwork()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            button
                .focused($isFocused)
            if title != nil || caption != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .font(.hearthText(25, weight: .medium, relativeTo: .callout))
                            .foregroundStyle(isFocused ? HearthColor.textPrimary : HearthColor.textSecondary)
                            .lineLimit(1)
                    }
                    if let caption {
                        Text(caption)
                            .font(.hearthTVCaption)
                            .foregroundStyle(HearthColor.textTertiary)
                            .lineLimit(1)
                    }
                }
                // Follows the card's lift so the words stay with it.
                .offset(y: isFocused ? 10 : 0)
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .accessibilityHidden(true)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private var button: some View {
        switch target {
        case .route(let route):
            NavigationLink(value: route) { label }
                .hearthCardButtonStyle()
                .accessibilityLabel(Text(accessibilityText))
        case .action(let action):
            Button(action: action) { label }
                .hearthCardButtonStyle()
                .accessibilityLabel(Text(accessibilityText))
        }
    }

    private var label: some View {
        artwork
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: HearthTVMetrics.cardRadius, style: .continuous))
    }

    private var accessibilityText: String {
        [title, caption].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A poster's face at TV size: the artwork (its title written on the
/// placeholder until it loads), a badge and a progress bar.
public struct TVPosterArtwork: View {
    public var title: String
    public var url: URL?
    public var badge: String?
    public var progress: Double?
    public var aspectRatio: CGFloat

    public init(title: String, url: URL?, badge: String? = nil, progress: Double? = nil, aspectRatio: CGFloat = 2.0 / 3.0) {
        self.title = title
        self.url = url
        self.badge = badge
        self.progress = progress
        self.aspectRatio = aspectRatio
    }

    public var body: some View {
        Rectangle()
            .fill(TilePalette.color(for: title))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.hearthDisplay(28, weight: .semibold, relativeTo: .title3))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(20)
                    .padding(.bottom, progress == nil ? 0 : 14)
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
            .overlay(alignment: .topLeading) {
                if let badge {
                    Text(badge)
                        .font(.hearthText(20, weight: .semibold, relativeTo: .caption))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(Capsule().fill(HearthColor.badgeScrim))
                        .foregroundStyle(.white)
                        .padding(16)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress {
                    HearthProgressBar(value: progress, height: 6, track: .overlay)
                        .padding(16)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A channel's face at TV size (16:9): logo, number and name, what's on now
/// with its times and progress, LIVE while there is a programme.
public struct TVChannelArtwork: View {
    public var name: String
    public var number: Int?
    public var logoURL: URL?
    public var programmeTitle: String?
    public var timing: ProgrammeTiming?
    public var now: Date

    public init(name: String, number: Int?, logoURL: URL?, programmeTitle: String?, timing: ProgrammeTiming?, now: Date = .now) {
        self.name = name
        self.number = number
        self.logoURL = logoURL
        self.programmeTitle = programmeTitle
        self.timing = timing
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                ChannelLogo(name: name, url: logoURL, size: 72)
                VStack(alignment: .leading, spacing: 2) {
                    if let number {
                        Text(verbatim: "\(number)")
                            .font(.hearthTVMono)
                            .foregroundStyle(HearthColor.textTertiary)
                    }
                    Text(name)
                        .font(.hearthText(26, weight: .semibold, relativeTo: .headline))
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let programmeTitle {
                HStack(spacing: 10) {
                    Circle().fill(HearthColor.accent).frame(width: 10, height: 10)
                    Text("LIVE", bundle: .module)
                        .font(.hearthText(18, weight: .bold, relativeTo: .caption2))
                        .tracking(1)
                        .foregroundStyle(HearthColor.accent)
                }
                Text(programmeTitle)
                    .font(.hearthText(24, relativeTo: .callout))
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 6)
            } else {
                Text("No guide", bundle: .module)
                    .font(.hearthText(22, relativeTo: .callout))
                    .foregroundStyle(HearthColor.textTertiary)
            }
            if let timing {
                HearthProgressBar(value: timing.progress(at: now), height: 6)
                    .padding(.top, 14)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 225, alignment: .topLeading)
        .background(HearthColor.surface)
        .accessibilityHidden(true)
    }
}

/// A page's heading on the TV: the title, and a line under it.
public struct TVPageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let accessory: Accessory

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.hearthTVLargeTitle)
                    .tracking(-0.8)
                    .foregroundStyle(HearthColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.hearthTVCallout)
                        .foregroundStyle(HearthColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension TVPageHeader where Accessory == EmptyView {
    public init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// A notice card on the TV: an icon, a title and a sentence or two. Used
/// where the TV deliberately does less than the phone ("Add sources from
/// your iPhone, iPad or Mac").
public struct TVNoticeCard: View {
    let systemName: String
    let title: String
    let message: String

    public init(systemName: String, title: String, message: String) {
        self.systemName = systemName
        self.title = title
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Image(systemName: systemName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(HearthColor.accent)
                .frame(width: 76, height: 76)
                .background(Circle().fill(HearthColor.surfaceRaised))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.hearthTVHeadline)
                    .foregroundStyle(HearthColor.textPrimary)
                Text(message)
                    .font(.hearthTVCallout)
                    .foregroundStyle(HearthColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: HearthTVMetrics.cardRadius, style: .continuous)
                .fill(HearthColor.surface)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reused screens

extension View {
    /// For a phone screen the TV shows as it is (Settings, Household): its
    /// fonts are sized `relativeTo:` text styles, so a larger Dynamic Type
    /// size scales them up to be read across the room. The TV has no Dynamic
    /// Type setting of its own; this sets one for the screen.
    public func hearthTVScaledText(_ enabled: Bool) -> some View {
        transformEnvironment(\.dynamicTypeSize) { size in
            if enabled { size = .accessibility2 }
        }
    }
}
