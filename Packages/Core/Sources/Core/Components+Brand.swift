import SwiftUI

// The brand mark and the profile gate's pieces: the amber TV-with-play glyph
// from the mockups' header (and the app icon), the "Hearth" lockup, a profile
// tile and the small status chip. Public API is additive to the contract in
// Components.swift.

/// The amber rounded TV with a play triangle: the profile gate's header logo
/// and the glyph on the app icon. Drawn from the mockup's 28 × 28 SVG so it
/// stays crisp at any size. Decorative: VoiceOver reads the lockup's name.
public struct HearthLogoMark: View {
    public var size: CGFloat
    public var color: Color

    public init(size: CGFloat = 28, color: Color = HearthColor.accent) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvas in
            let unit = min(canvas.width, canvas.height) / 28
            let shading = GraphicsContext.Shading.color(color)

            let screen = Path(
                roundedRect: CGRect(x: 2.5 * unit, y: 5 * unit, width: 23 * unit, height: 15.5 * unit),
                cornerRadius: 4 * unit, style: .continuous
            )
            context.stroke(screen, with: shading, style: StrokeStyle(lineWidth: 2 * unit))

            var stand = Path()
            stand.move(to: CGPoint(x: 10 * unit, y: 24 * unit))
            stand.addLine(to: CGPoint(x: 18 * unit, y: 24 * unit))
            context.stroke(stand, with: shading, style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round))

            var play = Path()
            play.move(to: CGPoint(x: 11.5 * unit, y: 9.5 * unit))
            play.addLine(to: CGPoint(x: 17 * unit, y: 12.75 * unit))
            play.addLine(to: CGPoint(x: 11.5 * unit, y: 16 * unit))
            play.closeSubpath()
            context.fill(play, with: shading)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The logo mark beside the app's name in Sora Bold, as at the top of
/// "Who's watching?". The name is a parameter because Hearth is a working
/// title (open question 3 in the handoff).
public struct HearthLogo: View {
    /// The name the lockup shows until the product is renamed.
    public static let defaultWordmark = "Hearth"

    public var wordmark: String?

    public init(wordmark: String? = HearthLogo.defaultWordmark) {
        self.wordmark = wordmark
    }

    public var body: some View {
        HStack(spacing: 10) {
            HearthLogoMark()
            if let wordmark {
                Text(wordmark)
                    .font(.hearthDisplay(21, weight: .bold, relativeTo: .title2))
                    .tracking(-0.21)
                    .foregroundStyle(HearthColor.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(wordmark ?? HearthLogo.defaultWordmark))
        .accessibilityAddTraits(.isHeader)
    }
}

/// A profile on the "Who's watching?" grid (PRF-1, PRF-3): the avatar, the
/// name with a lock when the profile asks for a PIN, and a status line
/// ("Mid-episode", "Kids profile"). A plain view: the profile gate wraps it
/// in a `Button` with `.buttonStyle(.hearthTile)`.
public struct ProfileTile: View {
    public var name: String
    public var palette: AvatarPalette
    public var symbol: String?
    public var subtitle: String?
    public var isLocked: Bool
    public var size: CGFloat

    public init(name: String, palette: AvatarPalette, symbol: String? = nil, subtitle: String? = nil, isLocked: Bool = false, size: CGFloat = 96) {
        self.name = name
        self.palette = palette
        self.symbol = symbol
        self.subtitle = subtitle
        self.isLocked = isLocked
        self.size = size
    }

    public var body: some View {
        VStack(spacing: 10) {
            AvatarTile(name: name, palette: palette, symbol: symbol, size: size, isLocked: isLocked)
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(.hearthText(16, weight: .medium, relativeTo: .body))
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.hearthCaption)
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isLocked ? String(localized: "\(name), locked with a PIN", bundle: .module) : name))
        .accessibilityValue(Text(subtitle ?? ""))
    }
}

/// A small dark chip beside a section title: "☁ Synced" on Home's Favorite
/// channels. Information, not a control.
public struct StatusChip: View {
    public var title: String
    public var systemImage: String?

    public init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.hearthText(11, relativeTo: .caption2))
                .lineLimit(1)
        }
        .foregroundStyle(HearthColor.textSecondary)
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .background(Capsule().fill(HearthColor.surface))
        .accessibilityElement(children: .combine)
    }
}
