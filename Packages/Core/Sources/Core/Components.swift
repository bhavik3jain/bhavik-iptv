import SwiftUI

// The shared building blocks of every screen in the mockups. Their initialisers
// are the contract the feature packages build against: change what they draw
// freely, change a signature only additively.

/// A profile's square avatar: a colour plus a letter or SF Symbol (PRF-1).
public struct AvatarTile: View {
    public var name: String
    public var palette: AvatarPalette
    public var symbol: String?
    public var size: CGFloat
    public var isLocked: Bool

    public init(name: String, palette: AvatarPalette, symbol: String? = nil, size: CGFloat = 96, isLocked: Bool = false) {
        self.name = name
        self.palette = palette
        self.symbol = symbol
        self.size = size
        self.isLocked = isLocked
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(palette.fill)
            .frame(width: size, height: size)
            .overlay {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(palette.ink)
                } else {
                    Text(Monogram.initials(for: name, maxLetters: 1))
                        .font(.hearthDisplay(size * 0.48, weight: .bold))
                        .foregroundStyle(palette.ink)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(name))
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
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(TilePalette.color(for: name))
            Text(Monogram.initials(for: name, maxLetters: 2))
                .font(.hearthText(size * 0.36, weight: .bold))
                .foregroundStyle(HearthColor.textPrimary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(size * 0.12)
                            .background(HearthColor.surfaceRaised)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A capsule filter chip: category pickers, "Favorites / All channels / News".
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
                .font(.hearthText(16, weight: .medium))
                .padding(.horizontal, 16)
                .frame(minHeight: HearthMetrics.minimumHitTarget)
                .foregroundStyle(isSelected ? HearthColor.onAccent : HearthColor.textPrimary)
                .background(
                    Capsule().fill(isSelected ? HearthColor.accent : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Color.clear : HearthColor.stroke, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A thin amber-on-track progress bar (programme progress, resume points).
public struct HearthProgressBar: View {
    public var value: Double
    public var height: CGFloat

    public init(value: Double, height: CGFloat = 4) {
        self.value = value
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(HearthColor.track)
                Capsule().fill(HearthColor.accent)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((min(max(value, 0), 1)) * 100)) percent"))
    }
}

/// A round icon button on a raised surface (search, AirPlay, close, guide
/// toggles). Always labelled for VoiceOver.
public struct IconCircleButton: View {
    public var systemName: String
    public var label: String
    public var size: CGFloat
    public var action: () -> Void

    public init(systemName: String, label: String, size: CGFloat = 44, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(HearthColor.textPrimary)
                .frame(width: max(size, HearthMetrics.minimumHitTarget), height: max(size, HearthMetrics.minimumHitTarget))
                .background(Circle().fill(HearthColor.surfaceRaised))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// "● LIVE" in amber.
public struct LiveBadge: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(HearthColor.accent).frame(width: 7, height: 7)
            Text("LIVE")
                .font(.hearthText(13, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(HearthColor.accent)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Live"))
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
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.hearthDisplay(24, weight: .semibold, relativeTo: .title2))
                .foregroundStyle(HearthColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
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

    /// `aspectRatio` is width / height: 2/3 for posters, 16/9 for stills.
    public init(url: URL?, title: String, aspectRatio: CGFloat = 2.0 / 3.0) {
        self.url = url
        self.title = title
        self.aspectRatio = aspectRatio
    }

    public var body: some View {
        Rectangle()
            .fill(TilePalette.color(for: title).gradient)
            .aspectRatio(aspectRatio, contentMode: .fit)
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

/// A poster tile with its title under or over it, an optional badge
/// ("S1 E7", "New · S3 E3") and an optional progress bar.
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
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: url, title: title)
                .clipShape(RoundedRectangle(cornerRadius: HearthMetrics.tileRadius, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.hearthText(12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .foregroundStyle(HearthColor.textPrimary)
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        HearthProgressBar(value: progress).padding(10)
                    }
                }
            Text(title)
                .font(.hearthText(15, weight: .medium))
                .foregroundStyle(HearthColor.textPrimary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
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
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(HearthColor.textTertiary)
            Text(title)
                .font(.hearthDisplay(22, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(HearthColor.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.hearthText(15))
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

/// The amber capsule button ("Resume", "Watch live").
public struct HearthPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hearthText(18, weight: .semibold))
            .padding(.horizontal, 24)
            .frame(minHeight: 52)
            .foregroundStyle(HearthColor.onAccent)
            .background(Capsule().fill(HearthColor.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// The dark raised button beside a primary one ("From the start").
public struct HearthSecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hearthText(18, weight: .medium))
            .padding(.horizontal, 24)
            .frame(minHeight: 52)
            .foregroundStyle(HearthColor.textPrimary)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(HearthColor.surfaceRaised))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension ButtonStyle where Self == HearthPrimaryButtonStyle {
    public static var hearthPrimary: HearthPrimaryButtonStyle { HearthPrimaryButtonStyle() }
}

extension ButtonStyle where Self == HearthSecondaryButtonStyle {
    public static var hearthSecondary: HearthSecondaryButtonStyle { HearthSecondaryButtonStyle() }
}

extension View {
    /// The rounded dark card every grouped section sits on.
    public func hearthCard(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous)
                    .fill(HearthColor.surface)
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
