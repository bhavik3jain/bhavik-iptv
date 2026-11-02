import Core
import SwiftUI

/// One multi-view tile on the Apple TV (PLY-9 at ten feet): one focusable
/// button whatever it shows, so a tile keeps focus when its channel starts,
/// fails or goes full screen. Focus is a thick white ring and a slight lift,
/// as tvOS draws it, which the screen can hide (`showsFocus`) while the remote
/// is idle; amber stays the mark of the tile with the sound.
///
/// A touch tile (`PlayerTileView`) takes taps on the picture, which the TV
/// doesn't have, and its type is sized for a hand's reach. Nothing here is
/// TV-only API, so a feature can use it without a platform conditional.
public struct TVPlayerTile: View {
    public enum Content {
        case playing(PlayerModel, hasSound: Bool, sourceName: String?)
        /// The full-screen player has this tile's picture.
        case fullScreen(name: String?)
        case empty(reason: String?)
    }

    private let content: Content
    private let hint: String?
    private let showsFocus: Bool
    private let action: () -> Void

    /// - Parameters:
    ///   - hint: What Select does on a playing tile, shown only while it has
    ///     focus; an empty tile's "Add a channel" already says. Also the hint
    ///     VoiceOver reads.
    ///   - showsFocus: Whether the focused tile looks focused, ring, lift and
    ///     hint. It keeps focus either way, so the remote still works on it.
    ///   - action: Select.
    public init(content: Content, hint: String?, showsFocus: Bool = true, action: @escaping () -> Void) {
        self.content = content
        self.hint = hint
        self.showsFocus = showsFocus
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            TVTileLabel(content: content, hint: hint, showsFocus: showsFocus)
        }
        .buttonStyle(TVTileButtonStyle(showsFocus: showsFocus))
    }
}

private enum TVTileMetrics {
    static let radius: CGFloat = 18
    /// Inside the 24 pt between tiles, so a lifted ring never covers a
    /// neighbour.
    static let focusRing: CGFloat = 8
    static let focusScale: CGFloat = 1.03
}

private struct TVTileLabel: View {
    let content: TVPlayerTile.Content
    let hint: String?
    let showsFocus: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Group {
            switch content {
            case .playing(let player, let hasSound, let sourceName):
                TVPlayingTile(player: player, hasSound: hasSound, sourceName: sourceName, hint: isFocused && showsFocus ? hint : nil)
            case .fullScreen(let name):
                TVTileMessage(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    title: name.map { String(localized: "\($0) is playing full screen") } ?? String(localized: "Playing full screen"),
                    message: nil,
                    isDashed: false
                )
            case .empty(let reason):
                TVTileMessage(
                    systemName: "plus",
                    title: String(localized: "Add a channel"),
                    message: reason,
                    isDashed: !isFocused
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TVTileMetrics.radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: TVTileMetrics.radius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenText))
        .accessibilityHint(Text(hint ?? ""))
        .accessibilityAddTraits(hasSound ? .isSelected : [])
    }

    private var hasSound: Bool {
        if case .playing(_, true, _) = content { return true }
        return false
    }

    private var spokenText: String {
        switch content {
        case .playing(let player, let hasSound, _):
            var parts = [PlayerFormat.itemLabel(player.item), player.item.title]
            if hasSound { parts.append(String(localized: "Sound on")) }
            if let message = player.state.failureMessage { parts.append(message) }
            return parts.joined(separator: ", ")
        case .fullScreen(let name):
            return name.map { String(localized: "\($0) is playing full screen") } ?? String(localized: "Playing full screen")
        case .empty(let reason):
            return reason.map { String(localized: "Add a channel. \($0)") } ?? String(localized: "Add a channel")
        }
    }
}

/// The picture, the channel chip, "Sound", the source, and the programme with
/// its progress along the bottom. A failed stream says so in place.
private struct TVPlayingTile: View {
    let player: PlayerModel
    let hasSound: Bool
    let sourceName: String?
    let hint: String?

    var body: some View {
        ZStack {
            Color.black
            player.videoView()
                .allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            status
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 8)
                footer
            }
            .padding(18)
        }
        .overlay {
            if hasSound {
                RoundedRectangle(cornerRadius: TVTileMetrics.radius, style: .continuous)
                    .strokeBorder(HearthColor.accent, lineWidth: 4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ChannelLogo(name: player.item.channelName ?? player.item.title, url: player.item.logoURL, size: 34)
                Text(PlayerFormat.itemLabel(player.item))
                    .font(.hearthText(23, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .frame(height: 46)
            .background(Capsule().fill(.black.opacity(0.6)))

            if hasSound {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text("Sound")
                        .font(.hearthText(23, weight: .semibold, relativeTo: .caption))
                }
                .foregroundStyle(HearthColor.onAccent)
                .padding(.horizontal, 16)
                .frame(height: 46)
                .background(Capsule().fill(HearthColor.accent))
                .fixedSize()
            }

            Spacer(minLength: 4)

            if let sourceName {
                Text(sourceName)
                    .font(.hearthText(20, relativeTo: .caption2))
                    .foregroundStyle(PlayerPalette.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.item.title)
                .font(.hearthText(26, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(HearthColor.accent)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 6)
            }
            if let hint {
                Text(hint)
                    .font(.hearthText(22, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let message = player.state.failureMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(HearthColor.accent)
                Text(message)
                    .font(.hearthText(22, relativeTo: .footnote))
                    .foregroundStyle(HearthColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.horizontal, 40)
        } else if player.state.isOpening || player.state == .buffering {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.white)
        }
    }

    /// As `PlayerTileView`: how far now is through the programme, for live.
    private var progress: Double? {
        let timeline = player.timeline
        guard timeline.showsBar else { return nil }
        return timeline.liveEdge ?? timeline.position
    }
}

/// A tile with no picture: a slot waiting for a channel, with the reason it
/// can't take one when the stream limits are why, or one showing full screen.
private struct TVTileMessage: View {
    let systemName: String
    let title: String
    let message: String?
    let isDashed: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(HearthColor.textPrimary)
                .frame(width: 84, height: 84)
                .background(Circle().fill(HearthColor.surfaceButton))
            Text(title)
                .font(.hearthText(30, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(HearthColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let message {
                Text(message)
                    .font(.hearthText(23, relativeTo: .footnote))
                    .foregroundStyle(HearthColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: TVTileMetrics.radius, style: .continuous).fill(HearthColor.surface))
        .overlay {
            if isDashed {
                RoundedRectangle(cornerRadius: TVTileMetrics.radius, style: .continuous)
                    .strokeBorder(HearthColor.hairline, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            }
        }
    }
}

/// The white ring and the lift, for a label the size of a picture.
private struct TVTileButtonStyle: ButtonStyle {
    let showsFocus: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVTileButtonBody(configuration: configuration, showsFocus: showsFocus)
    }
}

private struct TVTileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let showsFocus: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var looksFocused: Bool { isFocused && showsFocus }

    var body: some View {
        configuration.label
            .overlay {
                if looksFocused {
                    RoundedRectangle(cornerRadius: TVTileMetrics.radius + TVTileMetrics.focusRing, style: .continuous)
                        .strokeBorder(.white, lineWidth: TVTileMetrics.focusRing)
                        .padding(-TVTileMetrics.focusRing)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(scale)
            .shadow(color: .black.opacity(looksFocused ? 0.6 : 0), radius: 24, y: 12)
            .zIndex(isFocused ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: looksFocused)
    }

    private var scale: CGFloat {
        guard looksFocused, !reduceMotion else { return 1 }
        return configuration.isPressed ? 1 : TVTileMetrics.focusScale
    }
}
