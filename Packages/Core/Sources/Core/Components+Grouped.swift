import SwiftUI

// Household's building blocks (docs/handoff/ui/screens/Household.html):
// small-caps section labels, grouped cards of rows with hairline dividers,
// the stream bar (HH-5) and the overlapping avatars of a shared household.

/// "STREAMS RIGHT NOW": a small-caps label over a group, set loose. VoiceOver
/// reads the text as written, not letter by letter, and hears a header.
public struct SectionLabel: View {
    /// Size, colour and letter spacing, with the mockups' presets.
    public struct Style: Hashable, Sendable {
        public var size: CGFloat
        public var color: Color
        /// Letter spacing in em (0.06 = 6% of the size).
        public var tracking: CGFloat
        public var isHeader: Bool

        public init(size: CGFloat, color: Color, tracking: CGFloat = 0.06, isHeader: Bool = true) {
            self.size = size
            self.color = color
            self.tracking = tracking
            self.isHeader = isHeader
        }

        /// 13 pt grey over a grouped card: "PROFILES", "SOURCES".
        public static let section = Style(size: 13, color: HearthColor.textSecondary)
        /// 12 pt grey inside a card: "IN THIS HOUSEHOLD".
        public static let card = Style(size: 12, color: HearthColor.textSecondary)
        /// 12 pt amber over a title, not a header: the hero's "CONTINUE
        /// WATCHING".
        public static let eyebrow = Style(size: 12, color: HearthColor.accent, tracking: 0.08, isHeader: false)
        /// 11 pt in the Mac sidebar: "FAVORITE CHANNELS".
        public static let sidebar = Style(size: 11, color: HearthColor.textTertiary)
        /// 11 pt amber over a Mac panel's title: "NOW · 102 FIELDHOUSE SPORTS".
        public static let panel = Style(size: 11, color: HearthColor.accent, isHeader: false)
    }

    public var text: String
    public var style: Style

    public init(_ text: String, style: Style = .section) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.hearthText(style.size, weight: .semibold, relativeTo: style.size >= 13 ? .footnote : .caption))
            .tracking(style.size * style.tracking)
            .foregroundStyle(style.color)
            .accessibilityAddTraits(style.isHeader ? .isHeader : [])
    }
}

/// A rounded dark card of rows with a hairline between each, as every
/// Household section is drawn; optionally with a `SectionLabel` above and a
/// footnote below ("Logins are shared with everyone…").
///
/// Put rows straight in the builder (`CardRow`, `CardToggleRow`,
/// `CardActionRow`, `StreamBar`, or a `NavigationLink`/`Button` around a
/// `CardRow`); the dividers go between whatever rows are present, so a row
/// behind an `if` leaves no stray line.
public struct GroupedCard<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let rowPadding: CGFloat
    private let content: Content

    /// - Parameter rowPadding: Vertical padding inside each row, for rows
    ///   that have no minimum height of their own (the stream bars use 15).
    public init(title: String? = nil, footer: String? = nil, rowPadding: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.rowPadding = rowPadding
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                SectionLabel(title).padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle()
                                .fill(HearthColor.hairline)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                        row.padding(.vertical, rowPadding)
                    }
                }
            }
            .padding(.horizontal, HearthMetrics.groupedRowInset)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous)
                    .fill(HearthColor.surface)
            )
            if let footer {
                Text(footer)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A row in a `GroupedCard`: an optional leading tile, a title and subtitle,
/// optional trailing text ("Owner", "Active\nuntil Mar 2027"), an optional
/// trailing view, and a chevron when the row opens something.
///
/// A plain view, read by VoiceOver as one element; to make it act, wrap it in
/// a `NavigationLink` or `Button` with `.buttonStyle(.hearthTile)`.
public struct CardRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailingText: String?
    private let showsChevron: Bool
    private let minHeight: CGFloat?
    private let leading: Leading
    private let trailing: Trailing

    /// - Parameters:
    ///   - trailingText: Right-aligned grey text; a two-line value (with a
    ///     line break) is set a size smaller, as the Sources rows are.
    ///   - minHeight: Defaults to 64 with a subtitle and 48 without.
    public init(
        _ title: String,
        subtitle: String? = nil,
        trailingText: String? = nil,
        showsChevron: Bool = false,
        minHeight: CGFloat? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingText = trailingText
        self.showsChevron = showsChevron
        self.minHeight = minHeight
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hearthText(15, weight: subtitle == nil ? .regular : .medium, relativeTo: .body))
                    .foregroundStyle(HearthColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailingText {
                Text(trailingText)
                    .font(.hearthText(trailingText.contains("\n") ? 12 : 13, relativeTo: .footnote))
                    .foregroundStyle(HearthColor.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            trailing
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HearthColor.glyphMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: minHeight ?? (subtitle == nil ? 48 : 64))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension CardRow where Trailing == EmptyView {
    /// A row with a leading tile and nothing trailing but text or a chevron.
    public init(_ title: String, subtitle: String? = nil, trailingText: String? = nil, showsChevron: Bool = false, minHeight: CGFloat? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title, subtitle: subtitle, trailingText: trailingText, showsChevron: showsChevron, minHeight: minHeight, leading: leading) { EmptyView() }
    }
}

extension CardRow where Leading == EmptyView, Trailing == EmptyView {
    /// A text-only row.
    public init(_ title: String, subtitle: String? = nil, trailingText: String? = nil, showsChevron: Bool = false, minHeight: CGFloat? = nil) {
        self.init(title, subtitle: subtitle, trailingText: trailingText, showsChevron: showsChevron, minHeight: minHeight, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// The square at the start of a row: a source's type in amber Plex Mono
/// ("MAC", "XC", "M3U"), or a symbol (the household's house). Decorative:
/// the row's text already says what it shows.
public struct CardTile: View {
    private enum Glyph {
        case text(String)
        case symbol(String)
    }

    private let glyph: Glyph
    private let size: CGFloat

    /// A short code in amber mono, 38 pt by default.
    public init(text: String, size: CGFloat = 38) {
        self.glyph = .text(text)
        self.size = size
    }

    /// An SF Symbol in amber, 44 pt by default.
    public init(systemName: String, size: CGFloat = 44) {
        self.glyph = .symbol(systemName)
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(HearthColor.surfaceRaised)
            .frame(width: size, height: size)
            .overlay {
                switch glyph {
                case .text(let text):
                    Text(verbatim: text)
                        .font(.hearth(.mono, fixedSize: size * 0.29, weight: .semibold))
                        .foregroundStyle(HearthColor.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 3)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundStyle(HearthColor.accent)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A `GroupedCard` row with an amber switch: "Favorites for each profile".
public struct CardToggleRow: View {
    private let title: String
    private let subtitle: String?
    @Binding private var isOn: Bool

    public init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                }
            }
            .padding(.vertical, 8)
        }
        .toggleStyle(.amber)
        .frame(minHeight: 56)
    }
}

/// The amber action at the foot of a `GroupedCard`: "+ Add a portal, Xtream
/// login or playlist".
public struct CardActionRow: View {
    private let title: String
    private let systemImage: String
    private let action: () -> Void

    public init(_ title: String, systemImage: String = "plus", action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.hearthText(15, weight: .medium, relativeTo: .body))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(HearthColor.accent)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hearthTile)
    }
}

/// A source's streams in use (HH-5): "Provider B   1 of 2", one amber
/// segment per stream taken, and a caption saying who ("Anya · Living Room
/// iPad · Lantern Drama"). Over the limit ("Watch anyway", HH-6) the count
/// and segments turn red. A source with more slots than `StreamUsage
/// .maxSegments` gets one continuous bar; one with no limit gets no bar.
public struct StreamBar: View {
    public enum Size: Sendable {
        /// 15 pt name, 6 pt segments: Household's Streams right now.
        case regular
        /// 12 pt name, 5 pt segments: the foot of the Mac sidebar.
        case compact
    }

    public var name: String
    public var usage: StreamUsage
    public var caption: String?
    public var size: Size

    public init(_ name: String, usage: StreamUsage, caption: String? = nil, size: Size = .regular) {
        self.name = name
        self.usage = usage
        self.caption = caption
        self.size = size
    }

    private var regular: Bool { size == .regular }
    private var fill: Color { usage.isOverLimit ? HearthColor.danger : HearthColor.accent }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.hearthText(regular ? 15 : 12, relativeTo: regular ? .body : .caption))
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(usage.countText)
                    .font(.hearthMono(regular ? 13 : 12, relativeTo: regular ? .footnote : .caption))
                    .foregroundStyle(usage.isOverLimit ? HearthColor.danger : HearthColor.textSecondary)
            }
            bar
            if let caption {
                Text(caption)
                    .font(.hearthText(regular ? 13 : 12, relativeTo: regular ? .footnote : .caption))
                    .foregroundStyle(HearthColor.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text([usage.spokenText, caption].compactMap { $0 }.joined(separator: ", ")))
    }

    @ViewBuilder private var bar: some View {
        let height: CGFloat = regular ? 6 : 5
        if let segments = usage.segments {
            HStack(spacing: regular ? 4 : 3) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, taken in
                    Capsule()
                        .fill(taken ? fill : HearthColor.track)
                        .frame(height: height)
                }
            }
        } else if usage.limit != nil {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(HearthColor.track)
                    Capsule().fill(fill).frame(width: proxy.size.width * usage.fraction)
                }
            }
            .frame(height: height)
        }
    }
}

/// A household member as a round monogram: Household's member rows ("BJ"
/// on amber), and each face in an `AvatarStack`.
public struct AvatarCircle: View {
    public var name: String
    public var palette: AvatarPalette
    public var size: CGFloat

    public init(name: String, palette: AvatarPalette, size: CGFloat = 32) {
        self.name = name
        self.palette = palette
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(palette.fill)
            .frame(width: size, height: size)
            .overlay {
                Text(Monogram.initials(for: name, maxLetters: 2))
                    .font(.hearth(.display, fixedSize: size * 0.4, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(size * 0.1)
            }
            .accessibilityElement()
            .accessibilityLabel(Text(name))
    }
}

/// Overlapping member circles with a "+N" for the rest: "BJ AJ +1" on the
/// profile gate's household card. Each circle has a ring in the card's
/// colour so the overlaps read as separate faces. VoiceOver hears every name.
public struct AvatarStack: View {
    /// One person in the stack.
    public struct Member: Hashable, Sendable {
        public var name: String
        public var palette: AvatarPalette

        public init(name: String, palette: AvatarPalette) {
            self.name = name
            self.palette = palette
        }
    }

    public var members: [Member]
    public var maxVisible: Int
    public var size: CGFloat
    public var ringColor: Color

    /// - Parameters:
    ///   - maxVisible: Faces drawn before the rest become "+N".
    ///   - ringColor: The colour the stack sits on (the card's surface).
    public init(_ members: [Member], maxVisible: Int = 2, size: CGFloat = 30, ringColor: Color = HearthColor.surface) {
        self.members = members
        self.maxVisible = maxVisible
        self.size = size
        self.ringColor = ringColor
    }

    public var body: some View {
        let layout = AvatarStackLayout(count: members.count, maxVisible: maxVisible)
        HStack(spacing: -8) {
            ForEach(Array(members.prefix(layout.visible).enumerated()), id: \.offset) { _, member in
                ringed(AvatarCircle(name: member.name, palette: member.palette, size: size))
            }
            if layout.overflow > 0 {
                ringed(
                    Circle()
                        .fill(AvatarPalette.slate.fill)
                        .frame(width: size, height: size)
                        .overlay {
                            Text(verbatim: "+\(layout.overflow)")
                                .font(.hearth(.display, fixedSize: size * 0.4, weight: .semibold))
                                .foregroundStyle(AvatarPalette.slate.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AvatarStackLayout.spokenNames(members.map(\.name))))
    }

    private func ringed(_ avatar: some View) -> some View {
        avatar
            .padding(2)
            .background(Circle().fill(ringColor))
    }
}
