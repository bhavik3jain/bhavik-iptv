import Core
import SwiftUI

#if os(macOS)
import AppKit
#endif

// The small pieces the player screen and multi-view tiles are drawn with.
// Over a picture the app's opaque surfaces look like holes, so the player
// uses translucent white and black instead (mockup 06's own values).

enum PlayerPalette {
    /// Buttons and pills over the picture: rgba(255,255,255,0.14).
    static let glass = Color.white.opacity(0.14)
    /// The offset badge, a touch brighter than the buttons.
    static let badge = Color.white.opacity(0.16)
    /// Subtitles and times over the picture, lighter than the app's
    /// secondary text so they read on a bright frame.
    static let secondaryText = Color(hex: 0xD0D3DA)
    /// The scrub bar's track and its "up to live" fill.
    static let scrubTrack = Color.white.opacity(0.22)
    static let scrubLiveFill = Color.white.opacity(0.45)
}

/// A round translucent icon for the top bar's buttons and the tracks menu.
struct PlayerCircleIcon: View {
    var systemName: String
    var diameter: CGFloat = HearthMetrics.minimumHitTarget
    var fill: Color = PlayerPalette.glass
    var iconSize: CGFloat = 18

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }
}

/// A labelled round button over the picture (close, multi-view, PiP, ±10 s).
struct PlayerCircleButton: View {
    var systemName: String
    var label: LocalizedStringKey
    var diameter: CGFloat = HearthMetrics.minimumHitTarget
    var fill: Color = PlayerPalette.glass
    var iconSize: CGFloat = 18
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerCircleIcon(systemName: systemName, diameter: max(diameter, HearthMetrics.minimumHitTarget), fill: fill, iconSize: iconSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// A 32-point capsule over the picture ("‹ 101 Cityline News", "From the
/// start") inside a 44-point target.
struct PlayerPillButton: View {
    var title: String
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hearthText(13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(Capsule().fill(PlayerPalette.glass))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// The amber "● Jump to live" pill (PLY-2).
struct JumpToLiveButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(HearthColor.onAccent).frame(width: 7, height: 7)
                Text("Jump to live")
                    .font(.hearthText(13, weight: .semibold, relativeTo: .footnote))
            }
            .fixedSize()
            .foregroundStyle(HearthColor.onAccent)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Capsule().fill(HearthColor.accent))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Jump to live"))
    }
}

/// ⌘F on the Mac (MAC-2). The player usually sits in a sheet, which can't
/// go full screen itself, so the window the sheet hangs from does.
enum PlayerWindow {
    /// False where there is no window to toggle (iOS, or no key window), so
    /// the key passes on.
    @MainActor
    static func toggleFullScreen() -> Bool {
        #if os(macOS)
        guard let window = NSApp.keyWindow else { return false }
        (window.sheetParent ?? window).toggleFullScreen(nil)
        return true
        #else
        return false
        #endif
    }
}

extension VideoGravity {
    /// The tracks menu's wording (PLY-7).
    var title: LocalizedStringKey {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .zoom: "Zoom"
        }
    }

    var systemImage: String {
        switch self {
        case .fit: "rectangle.arrowtriangle.2.inward"
        case .fill: "rectangle.arrowtriangle.2.outward"
        case .zoom: "plus.magnifyingglass"
        }
    }
}

extension MediaTrack {
    /// The name the stream gives, its language when the name is empty, or
    /// "Track 2" as a last resort.
    func displayName(index: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if let language, let code = LanguageMatch.normalized(language),
           let name = Locale.current.localizedString(forLanguageCode: code) {
            return name
        }
        return String(localized: "Track \(index + 1)")
    }
}

extension PlaybackState {
    /// The message of a failed state, nil otherwise.
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// Before the first frame: idle until `start()` runs, then loading.
    var isOpening: Bool {
        self == .idle || self == .loading
    }
}
