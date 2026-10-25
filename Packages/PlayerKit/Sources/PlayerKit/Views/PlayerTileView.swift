import Core
import SwiftUI

/// One multi-view tile (PLY-9, mockup 07): the picture, the channel chip,
/// "Sound" on the tile that has it, the source's name, and the programme with
/// its progress along the bottom. An empty slot is a dashed "Add a channel"
/// button that says why, when the stream limits are the reason.
///
/// A tap on a playing tile calls `action` — the owner gives it the sound
/// (`MultiViewModel.giveSound(toTile:)`) or opens it full screen.
public struct PlayerTileView: View {
    private enum Content {
        case player(PlayerModel, hasSound: Bool, sourceName: String?)
        case empty(reason: String?)
    }

    private let content: Content
    private let action: () -> Void

    /// A playing tile.
    public init(player: PlayerModel, hasSound: Bool, sourceName: String? = nil, action: @escaping () -> Void) {
        self.content = .player(player, hasSound: hasSound, sourceName: sourceName)
        self.action = action
    }

    /// An empty slot; `reason` explains why it can't take a channel now.
    public init(emptyReason reason: String?, onAdd: @escaping () -> Void) {
        self.content = .empty(reason: reason)
        self.action = onAdd
    }

    /// A slot of a `MultiViewModel`, playing or empty.
    public init(tile: MultiViewModel.Tile, hasSound: Bool, sourceName: String? = nil, action: @escaping () -> Void) {
        if let player = tile.player {
            self.content = .player(player, hasSound: hasSound, sourceName: sourceName)
        } else {
            self.content = .empty(reason: tile.emptyReason)
        }
        self.action = action
    }

    public var body: some View {
        switch content {
        case .player(let player, let hasSound, let sourceName):
            PlayingTile(player: player, hasSound: hasSound, sourceName: sourceName, action: action)
        case .empty(let reason):
            EmptyTile(reason: reason, action: action)
        }
    }
}

private enum TileMetrics {
    static let radius: CGFloat = 14
}

private struct PlayingTile: View {
    let player: PlayerModel
    let hasSound: Bool
    let sourceName: String?
    let action: () -> Void

    var body: some View {
        ZStack {
            Color.black
            player.videoView()
                .allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            status
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 8)
                footer
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
        .overlay {
            if hasSound {
                RoundedRectangle(cornerRadius: TileMetrics.radius + 4, style: .continuous)
                    .strokeBorder(HearthColor.accent, lineWidth: 2)
                    .padding(-4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(hasSound ? .isSelected : [])
        .accessibilityHint(hasSound ? Text(verbatim: "") : Text("Plays this tile's sound"))
        .accessibilityAction { action() }
        .accessibilityActions {
            if player.state.failureMessage != nil {
                Button("Retry") {
                    Task { await player.retry() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ChannelLogo(name: channelName, url: player.item.logoURL, size: 18)
                Text(PlayerFormat.itemLabel(player.item))
                    .font(.hearthText(12, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 26)
            .background(Capsule().fill(.black.opacity(0.55)))

            if hasSound {
                HStack(spacing: 5) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Sound")
                        .font(.hearthText(12, weight: .semibold, relativeTo: .caption))
                }
                .foregroundStyle(HearthColor.onAccent)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(HearthColor.accent))
            }

            Spacer(minLength: 4)

            if let sourceName {
                Text(sourceName)
                    .font(.hearthText(11, relativeTo: .caption2))
                    .foregroundStyle(PlayerPalette.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(player.item.title)
                .font(.hearthText(14, weight: .medium, relativeTo: .subheadline))
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
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var status: some View {
        if let message = player.state.failureMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HearthColor.accent)
                Text(message)
                    .font(.hearthText(13, relativeTo: .footnote))
                    .foregroundStyle(HearthColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Retry") {
                    Task { await player.retry() }
                }
                .font(.hearthText(13, weight: .semibold, relativeTo: .footnote))
                .foregroundStyle(HearthColor.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(Capsule().fill(HearthColor.accent))
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
        } else if player.state.isOpening || player.state == .buffering {
            ProgressView()
                .tint(.white)
                .accessibilityHidden(true)
        }
    }

    private var channelName: String {
        player.item.channelName ?? player.item.title
    }

    /// The programme's progress for live (how far now is through it), the
    /// position for a movie; nil when there's nothing to measure against.
    private var progress: Double? {
        let timeline = player.timeline
        guard timeline.showsBar else { return nil }
        return timeline.liveEdge ?? timeline.position
    }

    private var accessibilityText: String {
        var parts = [PlayerFormat.itemLabel(player.item), player.item.title]
        if hasSound { parts.append(String(localized: "Sound on")) }
        if let message = player.state.failureMessage { parts.append(message) }
        return parts.joined(separator: ", ")
    }
}

private struct EmptyTile: View {
    let reason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HearthColor.textPrimary)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color(hex: 0x20232B)))
                Text("Add a channel")
                    .font(.hearthText(16, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(HearthColor.textPrimary)
                if let reason {
                    Text(reason)
                        .font(.hearthText(13, relativeTo: .footnote))
                        .foregroundStyle(HearthColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                    .fill(Color(hex: 0x121419))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                    .strokeBorder(Color(hex: 0x2F333D), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            )
            .contentShape(RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(reason.map { String(localized: "Add a channel. \($0)") } ?? String(localized: "Add a channel")))
    }
}

/// The multi-view grid (mockup 07): two tiles side by side, or four in two
/// rows, each 16:9. Tapping a playing tile gives it the sound; tapping an
/// empty one calls `onAdd` with its slot.
public struct MultiViewGrid: View {
    let model: MultiViewModel
    let sourceName: (PlayerItem) -> String?
    let onAdd: (Int) -> Void

    public init(model: MultiViewModel, sourceName: @escaping (PlayerItem) -> String? = { _ in nil }, onAdd: @escaping (Int) -> Void) {
        self.model = model
        self.sourceName = sourceName
        self.onAdd = onAdd
    }

    public var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(model.tiles) { tile in
                PlayerTileView(
                    tile: tile,
                    hasSound: tile.id == model.audibleTileID,
                    sourceName: tile.player.flatMap { sourceName($0.item) }
                ) {
                    if tile.isEmpty { onAdd(tile.id) } else { model.giveSound(toTile: tile.id) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
    }
}
