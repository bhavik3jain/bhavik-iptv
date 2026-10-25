import SwiftUI

/// Hearth's palette, read off the mockups' HTML in docs/handoff/ui/screens.
/// The app is dark only (a TV app: the picture is the brightest thing on
/// screen), so these are fixed colours rather than light/dark pairs.
public enum HearthColor {
    /// The window and screen background.
    public static let background = Color(hex: 0x0E0F12)
    /// Cards, grouped lists, header icon buttons, the guide's future
    /// programme cells.
    public static let surface = Color(hex: 0x17191F)
    /// Buttons and tiles sitting on a card ("Invite someone", a source's
    /// MAC tile, "From the start"), and the guide's on-air cells.
    public static let surfaceRaised = Color(hex: 0x262A33)
    /// The outline of unselected chips and the Edit button; the empty part of
    /// a stream bar.
    public static let stroke = Color(hex: 0x2A2E38)

    public static let textPrimary = Color(hex: 0xF2F1EE)
    public static let textSecondary = Color(hex: 0xA3A7B3)
    /// Guide times, placeholders, the Mac sidebar's section labels. Still
    /// 5.8:1 on the background, so it is fine for small text.
    public static let textTertiary = Color(hex: 0x8A8F9C)

    /// Hearth amber: the primary action, LIVE, the now line, selection.
    public static let accent = Color(hex: 0xF5B841)
    /// Text and glyphs drawn on amber.
    public static let onAccent = Color(hex: 0x1A1408)
    /// A progress track behind an amber fill, on a card or the background.
    public static let track = Color(hex: 0x2A2E38)

    public static let danger = Color(hex: 0xE5675A)
    public static let success = Color(hex: 0x58C08A)

    // MARK: Added with the design system pass

    /// Dividers between rows in a grouped card, and the outline of a card
    /// that sits on the background.
    public static let hairline = Color(hex: 0x23262E)
    /// The selected segment of `SegmentedPills`, the watched checkmark's disc,
    /// the slate avatar.
    public static let selection = Color(hex: 0x2A2E38)
    /// Floating panels over content: the guide's programme sheet.
    public static let surfaceOverlay = Color(hex: 0x1C1F26)
    /// Secondary buttons beside a primary one on a detail screen, the Manage
    /// household button, the Mac sidebar's selected row.
    public static let surfaceButton = Color(hex: 0x20232B)
    /// The Mac sidebar and the empty multi-view tile.
    public static let sidebar = Color(hex: 0x121419)
    /// The dashed outline of add tiles and an off toggle's track.
    public static let dashedStroke = Color(hex: 0x3A3F4B)
    /// Chevrons and other glyphs that should recede (not used for text).
    public static let glyphMuted = Color(hex: 0x6B7080)
    /// Secondary text drawn over artwork or a hero colour ("S2 · E5 — The
    /// Lighthouse Keeper", "31 min left").
    public static let textOnArtwork = Color(hex: 0xD3DCE0)
    /// Controls floating over video: the player's round buttons and badges.
    public static let overlayControl = Color.white.opacity(0.14)
    /// A progress track drawn over artwork or video.
    public static let overlayTrack = Color.white.opacity(0.22)
    /// The scrim behind a badge on artwork ("New · S3 E3").
    public static let badgeScrim = Color.black.opacity(0.45)
    /// The Continue watching hero and a show's header before its artwork
    /// loads: a deep teal that keeps the amber Resume button the brightest
    /// thing on it.
    public static let hero = Color(hex: 0x23404C)
    /// The darker shapes drawn on `hero` (the hill and beam source in the
    /// hero's decoration).
    public static let heroShade = Color(hex: 0x16303A)
    /// The line between the guide's channel rows and under the Mac toolbar:
    /// a shade lighter than the background, where `hairline` divides rows on
    /// a card.
    public static let rowDivider = Color(hex: 0x1A1C22)
}

/// The avatar colours a profile can take (PRF-1). Stored by HouseholdKit as a
/// raw string, so adding one is not a schema change.
public enum AvatarPalette: String, CaseIterable, Sendable, Codable {
    case amber, teal, lavender, slate, coral, green, blue, rose

    public var fill: Color {
        switch self {
        case .amber: Color(hex: 0xF5B841)
        case .teal: Color(hex: 0x4FC1B6)
        case .lavender: Color(hex: 0xA898FF)
        case .slate: Color(hex: 0x2A2E38)
        case .coral: Color(hex: 0xE88A6C)
        case .green: Color(hex: 0x5DBB7E)
        case .blue: Color(hex: 0x6C9CF0)
        case .rose: Color(hex: 0xE57BA2)
        }
    }

    /// The letter or symbol colour on that fill: a dark tint of the fill, as
    /// in the mockups, so a letter never reads as plain black.
    public var ink: Color {
        switch self {
        case .amber: Color(hex: 0x1A1408)
        case .teal: Color(hex: 0x0B2522)
        case .lavender: Color(hex: 0x1C1640)
        case .slate: Color(hex: 0xC9CCD4)
        case .coral: Color(hex: 0x2A120A)
        case .green: Color(hex: 0x0C2415)
        case .blue: Color(hex: 0x0D1A33)
        case .rose: Color(hex: 0x2E0F1C)
        }
    }
}

/// Muted tile colours for channel monograms and poster placeholders, picked
/// stably from a name so a channel keeps its colour across launches (LIV-7).
public enum TilePalette {
    /// The mockups' channel and poster colours. The count is part of the
    /// stable pick (`hash % count`): append rather than insert or remove, or
    /// every channel changes colour.
    public static let colors: [Color] = [
        Color(hex: 0x2F4B7C), Color(hex: 0x2E6B4F), Color(hex: 0x7A3B52),
        Color(hex: 0x23435A), Color(hex: 0x5A3A2E), Color(hex: 0x6B4FB8),
        Color(hex: 0x8A4B2A), Color(hex: 0x3C3360), Color(hex: 0x2E5B5B),
        Color(hex: 0x4B5A2E),
    ]

    public static func color(for name: String) -> Color {
        colors[index(for: name)]
    }

    /// The palette index for a name: FNV-1a, stable across launches and
    /// devices, unlike `hashValue`.
    public static func index(for name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(hash % UInt64(colors.count))
    }
}

extension Color {
    /// `Color(hex: 0xF5B841)`.
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
/// Mono for times and counts. Bundled in Core's resources (SIL OFL 1.1, see
/// Resources/Fonts/OFL.txt) and registered with Core Text for the process the
/// first time any `Font.hearth…` is asked for, so previews and tests of
/// feature packages get the real faces too. If a file is missing, that face
/// falls back to the system font at the same size and weight.
public enum HearthFonts {
    public static let display = "Sora"
    public static let text = "IBM Plex Sans"
    public static let mono = "IBM Plex Mono"

    /// Registers the bundled fonts with Core Text for this process. The app
    /// calls it once at launch; it is also run on first use and is safe to
    /// call again.
    public static func register() {
        HearthFontRegistration.ensureRegistered()
    }

    /// Whether `face` was found in Core's bundle and registered.
    public static func isRegistered(_ face: HearthFontFace) -> Bool {
        HearthFontRegistration.registeredPostScriptNames.contains(face.postScriptName)
    }
}

/// One of the three families, by role.
public enum HearthFontFamily: String, CaseIterable, Sendable {
    case display, text, mono

    /// The Core Text family name ("IBM Plex Sans").
    public var familyName: String {
        switch self {
        case .display: HearthFonts.display
        case .text: HearthFonts.text
        case .mono: HearthFonts.mono
        }
    }

    /// The faces bundled for this family, lightest first.
    public var faces: [HearthFontFace] {
        HearthFontFace.allCases.filter { $0.family == self }
    }
}

/// Every bundled face, named by its PostScript name.
///
/// Faces are asked for by PostScript name rather than family plus
/// `.weight(_:)`: the name is exact on both platforms, and the static IBM Plex
/// Sans files carry legacy names ("IBMPlexSans-SmBld", not "-SemiBold") that a
/// guessed name would miss. Sora publishes no Medium (neither as a static file
/// nor as a named instance of its variable font), so a medium Sora resolves to
/// SemiBold, which is also what SwiftUI picks for `.medium` on Sora's
/// variable font.
public enum HearthFontFace: String, CaseIterable, Sendable {
    case soraRegular = "Sora-Regular"
    case soraSemiBold = "Sora-SemiBold"
    case soraBold = "Sora-Bold"
    case plexSansRegular = "IBMPlexSans"
    case plexSansMedium = "IBMPlexSans-Medm"
    case plexSansSemiBold = "IBMPlexSans-SmBld"
    case plexSansBold = "IBMPlexSans-Bold"
    case plexMonoRegular = "IBMPlexMono-Regular"
    case plexMonoMedium = "IBMPlexMono-Medium"
    case plexMonoSemiBold = "IBMPlexMono-SemiBold"

    public var postScriptName: String { rawValue }

    public var family: HearthFontFamily {
        switch self {
        case .soraRegular, .soraSemiBold, .soraBold: .display
        case .plexSansRegular, .plexSansMedium, .plexSansSemiBold, .plexSansBold: .text
        case .plexMonoRegular, .plexMonoMedium, .plexMonoSemiBold: .mono
        }
    }

    /// The face's CSS-style weight: 400 regular … 700 bold.
    public var weightValue: Int {
        switch self {
        case .soraRegular, .plexSansRegular, .plexMonoRegular: 400
        case .plexSansMedium, .plexMonoMedium: 500
        case .soraSemiBold, .plexSansSemiBold, .plexMonoSemiBold: 600
        case .soraBold, .plexSansBold: 700
        }
    }

    /// The SwiftUI weight of this face, for the system-font fallback.
    public var weight: Font.Weight {
        switch weightValue {
        case 500: .medium
        case 600: .semibold
        case 700: .bold
        default: .regular
        }
    }

    /// The bundled face of `family` nearest to `weight`. Lighter than regular
    /// resolves to regular (no lighter faces are bundled); a tie between two
    /// faces goes to the heavier one, so Sora's missing Medium becomes
    /// SemiBold and Plex Mono's missing Bold becomes SemiBold.
    public static func face(_ family: HearthFontFamily, weight: Font.Weight) -> HearthFontFace {
        let wanted = cssWeight(weight)
        let faces = family.faces
        return faces.min { a, b in
            let da = abs(a.weightValue - wanted), db = abs(b.weightValue - wanted)
            return da == db ? a.weightValue > b.weightValue : da < db
        } ?? faces[0]
    }

    /// `Font.Weight` as a CSS weight (100…900). `Font.Weight` is neither
    /// comparable nor exposes its value, so the named weights are matched
    /// one by one; anything else is treated as regular.
    public static func cssWeight(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}

extension Font {
    /// Sora, for screen titles and hero titles. Scales with Dynamic Type
    /// relative to `textStyle`.
    public static func hearthDisplay(_ size: CGFloat, weight: Font.Weight = .bold, relativeTo textStyle: Font.TextStyle = .largeTitle) -> Font {
        hearth(.display, size: size, weight: weight, relativeTo: textStyle)
    }

    /// IBM Plex Sans, for everything that reads as text.
    public static func hearthText(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        hearth(.text, size: size, weight: weight, relativeTo: textStyle)
    }

    /// IBM Plex Mono, for times ("20:00 – 21:00"), channel numbers and counts
    /// ("1 of 2").
    public static func hearthMono(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle = .callout) -> Font {
        hearth(.mono, size: size, weight: weight, relativeTo: textStyle)
    }

    /// The face of `family` nearest `weight`, by PostScript name, scaling with
    /// Dynamic Type. Falls back to the system font (same size and weight,
    /// fixed) only if the bundled file is missing.
    public static func hearth(_ family: HearthFontFamily, size: CGFloat, weight: Font.Weight, relativeTo textStyle: Font.TextStyle) -> Font {
        let face = HearthFontFace.face(family, weight: weight)
        guard HearthFonts.isRegistered(face) else {
            return .system(size: size, weight: weight, design: family == .mono ? .monospaced : .default)
        }
        return .custom(face.postScriptName, size: size, relativeTo: textStyle)
    }

    /// The face of `family` nearest `weight` at a size that ignores Dynamic
    /// Type. Only for type that is part of a picture rather than text to read:
    /// the letter on an avatar or channel monogram, sized to its tile.
    public static func hearth(_ family: HearthFontFamily, fixedSize size: CGFloat, weight: Font.Weight) -> Font {
        let face = HearthFontFace.face(family, weight: weight)
        guard HearthFonts.isRegistered(face) else {
            return .system(size: size, weight: weight, design: family == .mono ? .monospaced : .default)
        }
        return .custom(face.postScriptName, fixedSize: size)
    }

    // MARK: Named styles from the mockups

    /// Sora SemiBold 30: "Who's watching?", "Household". Pair with
    /// `.tracking(HearthMetrics.titleTracking)`.
    public static var hearthLargeTitle: Font { .hearthDisplay(30, weight: .semibold, relativeTo: .largeTitle) }
    /// Sora SemiBold 28: tab screen titles ("Live TV").
    public static var hearthTitle: Font { .hearthDisplay(28, weight: .semibold, relativeTo: .title) }
    /// Sora SemiBold 19: section titles ("Favorite channels").
    public static var hearthSectionTitle: Font { .hearthDisplay(19, weight: .semibold, relativeTo: .title3) }
    /// Sora SemiBold 17: a sheet's or panel's title ("Evening Bulletin").
    public static var hearthHeadline: Font { .hearthDisplay(17, weight: .semibold, relativeTo: .headline) }
    /// Plex Sans 15: row titles and body text.
    public static var hearthBody: Font { .hearthText(15, relativeTo: .body) }
    /// Plex Sans 14: card titles, segment labels, chips.
    public static var hearthCallout: Font { .hearthText(14, relativeTo: .callout) }
    /// Plex Sans 13: row subtitles and footers.
    public static var hearthFootnote: Font { .hearthText(13, relativeTo: .footnote) }
    /// Plex Sans 12: captions and episode details.
    public static var hearthCaption: Font { .hearthText(12, relativeTo: .caption) }
}

/// Spacing and radii shared by every screen.
public enum HearthMetrics {
    /// The side margin of a phone screen (24 in every mockup but Household).
    public static let screenPadding: CGFloat = 24
    /// A card on the background: the profile-gate household card, the guide's
    /// programme sheet, Household's first card.
    public static let cardRadius: CGFloat = 20
    /// Posters ("Up next in your shows").
    public static let tileRadius: CGFloat = 14
    public static let chipRadius: CGFloat = 999
    /// Apple's minimum touch target (quality bar: accessibility).
    public static let minimumHitTarget: CGFloat = 44

    // MARK: Added with the design system pass

    /// Grouped rows (Household's Profiles, Sources, Sync) and channel cards.
    public static let groupedCardRadius: CGFloat = 18
    /// The Continue watching hero.
    public static let heroRadius: CGFloat = 24
    /// Episode stills and multi-view tiles.
    public static let stillRadius: CGFloat = 12
    /// A rounded control on a card: "Manage household", "Invite someone",
    /// the sheet's buttons.
    public static let controlRadius: CGFloat = 12
    /// The inner padding of a grouped card's rows.
    public static let groupedRowInset: CGFloat = 16
    /// Between a screen's sections (Home: hero, channels, shows).
    public static let sectionSpacing: CGFloat = 26
    /// Between items in a row of cards, and a section title and its content.
    public static let itemSpacing: CGFloat = 12
    /// Sora titles are set tight: -0.02 em at 30 pt.
    public static let titleTracking: CGFloat = -0.6
    /// Small-caps section labels are set loose: 0.06 em at 13 pt.
    public static let labelTracking: CGFloat = 0.8
}
