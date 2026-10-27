#if os(tvOS)
import Core
import SwiftUI

/// The player on the Apple TV (mockup 06 at ten feet), driven by the Siri
/// Remote rather than touch.
///
/// While the controls are hidden the whole picture is one focused surface:
/// click or swipe left and right to skip 10 seconds, up and down to change
/// channel (live), select to bring up the controls, Play/Pause to pause, Menu
/// to close. Clicks and swipes both arrive as focus moves, so the surface is
/// ringed by four invisible targets: moving onto one does its action and
/// hands focus straight back to the picture. A skip shows the timeline without taking focus off the picture,
/// so a run of skips stays a run of skips. Select moves focus into the
/// controls (−10, play, +10, the live pills, the channel pills, tracks), where
/// the focus engine walks them; Menu there goes back to the picture, and so
/// does the controls' fade.
struct TVPlayerScreen: View {
    let model: PlayerModel

    /// Focus is in the controls (select was pressed); otherwise on the picture.
    @State private var controlsActive = false
    @FocusState private var focus: TVPlayerFocus?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var failureMessage: String? { model.state.failureMessage }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            model.videoView()
                .ignoresSafeArea()
                .accessibilityHidden(true)

            remoteSurface

            if model.controlsVisible || failureMessage != nil {
                TVPlayerOverlay(model: model, isInteractive: controlsActive, focus: $focus)
                    .transition(.opacity)
            } else if model.state == .buffering || model.state.isOpening {
                ProgressView()
                    .scaleEffect(1.6)
                    .tint(.white)
                    .accessibilityLabel(Text("Loading"))
            }

            if let failureMessage {
                TVPlayerErrorPanel(model: model, message: failureMessage, focus: $focus)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.controlsVisible)
        .environment(\.colorScheme, .dark)
        .onPlayPauseCommand {
            model.togglePlayPause()
            model.showControls()
        }
        .onExitCommand {
            if controlsActive, failureMessage == nil {
                leaveControls()
            } else {
                model.close()
            }
        }
        .onChange(of: focus) { _, newValue in
            guard let newValue, let direction = newValue.direction else { return }
            move(direction)
            focus = .surface
        }
        .onChange(of: model.controlsVisible) { _, visible in
            // The fade puts focus back on the picture.
            if !visible { leaveControls() }
        }
        .onChange(of: failureMessage) { _, message in
            if message != nil {
                controlsActive = true
                focus = .retry
            }
        }
        .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
            // Controls that fade can't be reached with VoiceOver.
            model.autoHidesControls = !enabled
            if enabled { controlsActive = true }
        }
        .onAppear { focus = .surface }
        .task { await model.start() }
    }

    /// The picture as the remote's target: a button so select reaches it,
    /// drawn as nothing at all.
    private var surface: some View {
        Button {
            enterControls()
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(TVInvisibleButtonStyle())
        .focused($focus, equals: .surface)
        .disabled(controlsActive)
        .accessibilityLabel(Text(model.item.title))
        .accessibilityHint(Text("Shows the player controls"))
    }

    /// The surface with its four edges, edge to edge.
    private var remoteSurface: some View {
        HStack(spacing: 0) {
            edge(.edge(.left)).frame(width: 40)
            VStack(spacing: 0) {
                edge(.edge(.up)).frame(height: 40)
                surface
                edge(.edge(.down)).frame(height: 40)
            }
            edge(.edge(.right)).frame(width: 40)
        }
        .ignoresSafeArea()
    }

    private func edge(_ value: TVPlayerFocus) -> some View {
        Button {} label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(TVInvisibleButtonStyle())
        .focused($focus, equals: value)
        .disabled(controlsActive)
        .accessibilityHidden(true)
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            guard model.canSeek else { return model.showControls() }
            model.skip(by: -10)
            model.showControls()
        case .right:
            guard model.canSeek, !(model.item.isLive && model.isAtLiveEdge) else { return model.showControls() }
            model.skip(by: 10)
            model.showControls()
        case .up:
            // Channel up is the next number, as on every remote (LIV-5).
            if model.item.isLive, model.canGoToNextItem {
                Task { await model.goToNextItem() }
                model.showControls()
            } else {
                enterControls()
            }
        case .down:
            if model.item.isLive, model.canGoToPreviousItem {
                Task { await model.goToPreviousItem() }
                model.showControls()
            } else {
                enterControls()
            }
        @unknown default:
            break
        }
    }

    private func enterControls() {
        model.showControls()
        controlsActive = true
        focus = failureMessage == nil ? .playPause : .retry
    }

    private func leaveControls() {
        guard !voiceOverEnabled else { return }
        controlsActive = false
        focus = .surface
    }
}

// MARK: - Overlay

/// What is drawn over the picture while the controls show: the title at the
/// top, −10 · play · +10 in the middle, the live pills, scrub bar, times and
/// channel pills at the foot. Buttons take focus only once `isInteractive`.
private struct TVPlayerOverlay: View {
    let model: PlayerModel
    let isInteractive: Bool
    var focus: FocusState<TVPlayerFocus?>.Binding

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
                Spacer(minLength: 0)
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 340)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                TVPlayerTopBar(model: model, isInteractive: isInteractive)
                Spacer(minLength: 24)
                if model.state.failureMessage == nil {
                    TVPlayerCenterControls(model: model, isInteractive: isInteractive, focus: focus)
                }
                Spacer(minLength: 24)
                if model.state.failureMessage == nil {
                    TVPlayerBottomBar(model: model, isInteractive: isInteractive)
                }
            }
            // The TV's safe area already keeps clear of overscan.
            .padding(.vertical, 8)
        }
    }
}

/// Where focus can be sent: the picture, its four edges, the play button,
/// the error's Retry.
enum TVPlayerFocus: Hashable {
    case surface
    case edge(MoveCommandDirection)
    case playPause
    case retry

    var direction: MoveCommandDirection? {
        if case .edge(let direction) = self { return direction }
        return nil
    }
}

/// The channel's logo, its name and programme (or the title and episode),
/// and the tracks menu.
private struct TVPlayerTopBar: View {
    let model: PlayerModel
    let isInteractive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            if let logoName {
                ChannelLogo(name: logoName, url: model.item.logoURL, size: 80)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.item.title)
                    .font(.hearthDisplay(40, weight: .semibold, relativeTo: .title))
                    .foregroundStyle(.white)
                if let subtitle = model.item.subtitle {
                    Text(subtitle)
                        .font(.hearthText(26, relativeTo: .headline))
                        .foregroundStyle(PlayerPalette.secondaryText)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if hasTracks {
                TVPlayerTracksMenu(model: model)
                    .disabled(!isInteractive)
            }
        }
    }

    private var logoName: String? {
        model.item.channelName ?? (model.item.isLive ? model.item.title : nil)
    }

    /// Picture size is always there; the menu is worth a button even with
    /// one audio track.
    private var hasTracks: Bool { true }
}

/// Audio, subtitles and picture size (PLY-6, PLY-7) as the TV's menu.
private struct TVPlayerTracksMenu: View {
    let model: PlayerModel

    var body: some View {
        Menu {
            if !model.audioTracks.isEmpty {
                Picker("Audio", selection: audioSelection) {
                    ForEach(Array(model.audioTracks.enumerated()), id: \.element.id) { index, track in
                        Text(track.displayName(index: index)).tag(Optional(track.id))
                    }
                }
            }
            Picker("Subtitles", selection: subtitleSelection) {
                Text("Off").tag(String?.none)
                ForEach(Array(model.subtitleTracks.enumerated()), id: \.element.id) { index, track in
                    Text(track.displayName(index: index)).tag(Optional(track.id))
                }
            }
            Picker("Picture", selection: gravitySelection) {
                ForEach(VideoGravity.allCases, id: \.self) { gravity in
                    Label(gravity.title, systemImage: gravity.systemImage).tag(gravity)
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 88, height: 88)
        }
        .menuStyle(.button)
        .buttonStyle(TVPlayerGlassButtonStyle(shape: .circle))
        .accessibilityLabel(Text("Audio, subtitles and picture size"))
    }

    private var audioSelection: Binding<String?> {
        Binding(
            get: { model.selectedAudioTrackID },
            set: { id in if let id { model.selectAudioTrack(id: id) } }
        )
    }

    private var subtitleSelection: Binding<String?> {
        Binding(
            get: { model.selectedSubtitleTrackID },
            set: { id in model.selectSubtitleTrack(id: id) }
        )
    }

    private var gravitySelection: Binding<VideoGravity> {
        Binding(
            get: { model.gravity },
            set: { model.gravity = $0 }
        )
    }
}

/// −10 · play/pause · +10 (PLY-2), large enough to read across a room.
private struct TVPlayerCenterControls: View {
    let model: PlayerModel
    let isInteractive: Bool
    var focus: FocusState<TVPlayerFocus?>.Binding

    var body: some View {
        HStack(spacing: 72) {
            TVPlayerCircleButton(systemName: "gobackward.10", label: "Back 10 seconds", diameter: 104, iconSize: 40) {
                model.skip(by: -10)
                model.showControls()
            }
            .disabled(!isInteractive || !model.canSeek)
            .opacity(model.canSeek ? 1 : 0.35)

            centre

            TVPlayerCircleButton(systemName: "goforward.10", label: "Forward 10 seconds", diameter: 104, iconSize: 40) {
                model.skip(by: 10)
                model.showControls()
            }
            .disabled(!isInteractive || !canSkipForward)
            .opacity(canSkipForward ? 1 : 0.35)
        }
    }

    @ViewBuilder
    private var centre: some View {
        if model.state.isOpening {
            ProgressView()
                .scaleEffect(1.6)
                .tint(.white)
                .frame(width: 136, height: 136)
                .background(Circle().fill(.black.opacity(0.45)))
                .accessibilityLabel(Text("Loading"))
        } else if model.state == .ended {
            TVPlayerCircleButton(systemName: "arrow.counterclockwise", label: "Play again", diameter: 136, iconSize: 52) {
                model.play()
            }
            .focused(focus, equals: .playPause)
            .disabled(!isInteractive)
        } else {
            TVPlayerCircleButton(
                systemName: model.isPlaying ? "pause.fill" : "play.fill",
                label: model.isPlaying ? "Pause" : "Play",
                diameter: 136,
                iconSize: 52
            ) {
                model.togglePlayPause()
                model.showControls()
            }
            .focused(focus, equals: .playPause)
            .disabled(!isInteractive)
        }
    }

    private var canSkipForward: Bool {
        model.canSeek && !(model.item.isLive && model.isAtLiveEdge)
    }
}

/// The live row (LIVE and From the start, or how far behind and Jump to
/// live), the bar, its times and the neighbouring channels.
private struct TVPlayerBottomBar: View {
    let model: PlayerModel
    let isInteractive: Bool

    var body: some View {
        let timeline = model.timeline
        VStack(alignment: .leading, spacing: 14) {
            if model.item.isLive {
                liveRow
            }
            if timeline.showsBar {
                TVPlayerProgressBar(timeline: timeline)
                    .accessibilityElement()
                    .accessibilityLabel(Text(model.item.isLive ? "Playback position, live" : "Playback position"))
                    .accessibilityValue(Text(timeline.positionLabel))
            }
            HStack(spacing: 20) {
                Text(timeline.leadingLabel)
                    .font(.hearthMono(24, relativeTo: .caption))
                    .foregroundStyle(PlayerPalette.secondaryText)
                    .fixedSize()
                    .accessibilityHidden(true)
                Spacer(minLength: 20)
                if let previous = model.previousItemTitle {
                    TVPlayerPillButton(
                        title: "‹ " + previous,
                        accessibilityLabel: model.item.isLive
                            ? String(localized: "Previous channel, \(previous)")
                            : String(localized: "Previous, \(previous)")
                    ) {
                        Task { await model.goToPreviousItem() }
                    }
                    .disabled(!isInteractive)
                }
                if let next = model.nextItemTitle {
                    TVPlayerPillButton(
                        title: next + " ›",
                        accessibilityLabel: model.item.isLive
                            ? String(localized: "Next channel, \(next)")
                            : String(localized: "Next, \(next)")
                    ) {
                        Task { await model.goToNextItem() }
                    }
                    .disabled(!isInteractive)
                }
                Spacer(minLength: 20)
                Text(timeline.trailingLabel)
                    .font(.hearthMono(24, relativeTo: .caption))
                    .foregroundStyle(PlayerPalette.secondaryText)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 66)
        }
    }

    private var liveRow: some View {
        HStack(spacing: 20) {
            if model.isAtLiveEdge {
                TVLiveBadge()
                if model.canPlayFromStart {
                    TVPlayerPillButton(title: String(localized: "From the start"), accessibilityLabel: String(localized: "Play from the start")) {
                        Task { await model.playFromStart() }
                    }
                    .disabled(!isInteractive)
                }
            } else {
                Text(PlayerFormat.behindLive(model.liveOffset))
                    .font(.hearthMono(24, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PlayerPalette.badge))
                    .fixedSize()
                    .accessibilityLabel(Text("\(HearthFormat.timecode(model.liveOffset)) behind live"))
                Text(PlayerFormat.liveCaption(
                    isPaused: model.state == .paused,
                    catchUpFrom: model.item.hasArchive ? model.item.programmeStart : nil
                ))
                .font(.hearthText(24, relativeTo: .footnote))
                .foregroundStyle(PlayerPalette.secondaryText)
                .lineLimit(1)
            }
            Spacer(minLength: 20)
            if !model.isAtLiveEdge {
                TVPlayerPillButton(title: String(localized: "● Jump to live"), accessibilityLabel: String(localized: "Jump to live"), isProminent: true) {
                    Task { await model.jumpToLive() }
                }
                .disabled(!isInteractive)
            }
        }
        .frame(minHeight: 66)
    }
}

/// The bar of mockup 06, display only: on the TV the remote skips, it
/// doesn't drag.
private struct TVPlayerProgressBar: View {
    let timeline: PlaybackTimeline

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(PlayerPalette.scrubTrack).frame(height: 8)
                if let edge = timeline.liveEdge {
                    Capsule().fill(PlayerPalette.scrubLiveFill).frame(width: width * edge, height: 8)
                }
                Capsule().fill(HearthColor.accent).frame(width: width * timeline.position, height: 8)
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.3), radius: 3)
                    .offset(x: width * timeline.position - 12)
            }
            .frame(width: width, height: proxy.size.height)
        }
        .frame(height: 28)
    }
}

/// LIVE in the player's own size.
private struct TVLiveBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(HearthColor.onAccent).frame(width: 12, height: 12)
            Text("LIVE")
                .font(.hearthText(22, weight: .bold, relativeTo: .caption))
                .tracking(1)
        }
        .foregroundStyle(HearthColor.onAccent)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Capsule().fill(HearthColor.accent))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Live"))
    }
}

// MARK: - Errors

/// PLY-4's last word on the TV: Retry first in focus, Try another source
/// when the household has the channel elsewhere, Menu to close.
private struct TVPlayerErrorPanel: View {
    let model: PlayerModel
    let message: String
    var focus: FocusState<TVPlayerFocus?>.Binding

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(HearthColor.accent)
                .accessibilityHidden(true)
            Text(model.item.isLive ? "This channel couldn't play" : "This couldn't play")
                .font(.hearthDisplay(40, weight: .semibold, relativeTo: .title2))
                .foregroundStyle(HearthColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.hearthText(26, relativeTo: .body))
                .foregroundStyle(HearthColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                Button("Retry") {
                    Task { await model.retry() }
                }
                .focused(focus, equals: .retry)
                if let tryAnotherSource = model.onTryAnotherSource {
                    Button("Try another source", action: tryAnotherSource)
                }
                Button("Close") { model.close() }
            }
            .padding(.top, 8)
        }
        .padding(56)
        .frame(maxWidth: 900)
        .background(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(HearthColor.surface.opacity(0.96))
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Buttons

/// A round translucent button over the picture that grows and turns amber
/// with focus.
private struct TVPlayerCircleButton: View {
    var systemName: String
    var label: LocalizedStringKey
    var diameter: CGFloat
    var iconSize: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(TVPlayerGlassButtonStyle(shape: .circle))
        .accessibilityLabel(Text(label))
    }
}

/// A capsule over the picture ("‹ 101 Cityline News", "From the start").
private struct TVPlayerPillButton: View {
    var title: String
    var accessibilityLabel: String
    var isProminent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hearthText(24, weight: .medium, relativeTo: .footnote))
                .lineLimit(1)
                .padding(.horizontal, 24)
                .frame(minHeight: 56)
        }
        .buttonStyle(TVPlayerGlassButtonStyle(shape: .capsule, isProminent: isProminent))
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// Glass at rest; white with dark ink, a little larger, when focused (the
/// tvOS convention for controls over video). Amber when prominent.
private struct TVPlayerGlassButtonStyle: ButtonStyle {
    enum Shape { case circle, capsule }
    var shape: Shape
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, shape: shape, isProminent: isProminent)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let shape: Shape
        let isProminent: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background { background }
                .scaleEffect(configuration.isPressed ? 1.0 : (isFocused ? 1.12 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 16, y: 8)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }

        private var foreground: Color {
            if isFocused { return isProminent ? HearthColor.onAccent : Color(hex: 0x111216) }
            return isProminent ? HearthColor.onAccent : .white
        }

        private var fill: Color {
            if isProminent { return isFocused ? HearthColor.accent : HearthColor.accent.opacity(0.9) }
            return isFocused ? .white : .black.opacity(0.4)
        }

        @ViewBuilder
        private var background: some View {
            switch shape {
            case .circle: Circle().fill(fill)
            case .capsule: Capsule().fill(fill)
            }
        }
    }
}

/// Draws the label and nothing else, focused or not: the picture surface.
private struct TVInvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif
