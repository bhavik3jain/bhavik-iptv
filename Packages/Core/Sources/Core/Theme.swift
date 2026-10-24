import SwiftUI

/// Hearth's palette, read off the mockups in docs/handoff/ui. The app is dark
/// only (a TV app: the picture is the brightest thing on screen), so these are
/// fixed colours rather than light/dark pairs.
public enum HearthColor {
    /// The window and screen background.
    public static let background = Color(hex: 0x0E0F12)
    /// Cards, list groups, the guide's programme cells.
    public static let surface = Color(hex: 0x1A1C22)
    /// Buttons on a card, the selected segment, chips.
    public static let surfaceRaised = Color(hex: 0x24272F)
    /// Hairlines and the outline of unselected chips.
    public static let stroke = Color(hex: 0x2C2F38)

    public static let textPrimary = Color(hex: 0xF4F4F2)
    public static let textSecondary = Color(hex: 0xA2A7B0)
    public static let textTertiary = Color(hex: 0x6E7480)

    /// Hearth amber: the primary action, LIVE, the now line, selection.
    public static let accent = Color(hex: 0xF5B942)
    /// Text and glyphs drawn on amber.
    public static let onAccent = Color(hex: 0x1C1405)
    /// A progress track behind an amber fill.
    public static let track = Color(hex: 0x3A3E48)

    public static let danger = Color(hex: 0xE5675A)
    public static let success = Color(hex: 0x58C08A)
}

/// The avatar colours a profile can take (PRF-1). Stored by HouseholdKit as a
/// raw string, so adding one is not a schema change.
public enum AvatarPalette: String, CaseIterable, Sendable, Codable {
    case amber, teal, lavender, slate, coral, green, blue, rose

    public var fill: Color {
        switch self {
        case .amber: Color(hex: 0xF5B942)
        case .teal: Color(hex: 0x4FC1B6)
        case .lavender: Color(hex: 0xA99BFF)
        case .slate: Color(hex: 0x2A2E38)
        case .coral: Color(hex: 0xE88A6C)
        case .green: Color(hex: 0x5DBB7E)
        case .blue: Color(hex: 0x6C9CF0)
        case .rose: Color(hex: 0xE57BA2)
        }
    }

    /// The letter or symbol colour on that fill.
    public var ink: Color {
        switch self {
        case .slate: Color(hex: 0xD9DCE2)
        default: Color(hex: 0x16181D)
        }
    }
}

/// Muted tile colours for channel monograms and poster placeholders, picked
/// stably from a name so a channel keeps its colour across launches (LIV-7).
public enum TilePalette {
    public static let colors: [Color] = [
        Color(hex: 0x2D4A7A), Color(hex: 0x2F6E4F), Color(hex: 0x7A3A52),
        Color(hex: 0x24465C), Color(hex: 0x5C3A2E), Color(hex: 0x6C4FC8),
        Color(hex: 0x8A4A2B), Color(hex: 0x3D3A6B), Color(hex: 0x2E5B5B),
        Color(hex: 0x4D5A2A),
    ]

    public static func color(for name: String) -> Color {
        // FNV-1a: stable across launches, unlike `hashValue`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

extension Color {
    /// `Color(hex: 0xF5B942)`.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The three typefaces: Sora for display, IBM Plex Sans for text, IBM Plex
/// Mono for times and counts. Bundled in Core's resources (SIL OFL 1.1) and
/// registered at launch by `HearthFonts.register()`; until registered, or if a
/// file is missing, SwiftUI falls back to the system font.
public enum HearthFonts {
    public static let display = "Sora"
    public static let text = "IBM Plex Sans"
    public static let mono = "IBM Plex Mono"

    /// Registers the bundled fonts with Core Text for this process. Call once
    /// at launch; safe to call again.
    public static func register() {
        HearthFontRegistration.registerBundledFonts()
    }
}

extension Font {
    /// Sora, for screen titles and hero titles. Scales with Dynamic Type
    /// relative to `textStyle`.
    public static func hearthDisplay(_ size: CGFloat, weight: Font.Weight = .bold, relativeTo textStyle: Font.TextStyle = .largeTitle) -> Font {
        .custom(HearthFonts.display, size: size, relativeTo: textStyle).weight(weight)
    }

    /// IBM Plex Sans, for everything that reads as text.
    public static func hearthText(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom(HearthFonts.text, size: size, relativeTo: textStyle).weight(weight)
    }

    /// IBM Plex Mono, for times ("20:00 – 21:00"), channel numbers and counts
    /// ("1 of 2").
    public static func hearthMono(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .callout) -> Font {
        .custom(HearthFonts.mono, size: size, relativeTo: textStyle).weight(weight)
    }
}

/// Spacing and radii shared by every screen.
public enum HearthMetrics {
    public static let screenPadding: CGFloat = 20
    public static let cardRadius: CGFloat = 22
    public static let tileRadius: CGFloat = 16
    public static let chipRadius: CGFloat = 999
    /// Apple's minimum touch target (quality bar: accessibility).
    public static let minimumHitTarget: CGFloat = 44
}
