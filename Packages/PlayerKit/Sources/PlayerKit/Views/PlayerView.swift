import Core
import SwiftUI

/// The full-screen player (mockup 06): video edge to edge, controls in the
/// safe area, catch-up timeline, channel pills, PiP, AirPlay, tracks.
///
/// Only the picture and the scrims run under the notch, the Dynamic Island
/// and the home indicator; every control sits inside the safe area, which on
/// a landscape iPhone (and iPhone Duo's inner display) is not symmetric, so
/// nothing here assumes the left and right insets match. Layout follows the
/// space the screen gets, not the device: under 560 points wide (an iPhone in
/// portrait, Duo folded) the logo and the multi-view button step aside.
///
/// Keys (MAC-2, and an iPad keyboard): space plays and pauses, ← and → skip
/// 10 seconds, ↑ and ↓ change channel, Esc closes, and on the Mac ⌘F turns
/// the window full screen (unless the app's menu claims ⌘F first: menu key
/// equivalents run before a view sees the key).
///
/// The view starts the model when it appears; closing is the model's (the X,
/// Esc, or the owner calling `close()`), so the owner hears `onClose` and
/// dismisses. Disappearing alone doesn't close it — the same model may go on
/// playing in a multi-view tile.
public struct PlayerView: View {
    let model: PlayerModel

    public init(model: PlayerModel) {
        self.model = model
    }

    @FocusState private var hasKeyboardFocus: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        #if os(tvOS)
        // The Siri Remote's player: focus, not taps and keys (PlayerView+TV).
        TVPlayerScreen(model: model)
        #else
        touchAndKeyboardBody
        #endif
    }

    private var touchAndKeyboardBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            model.videoView()
                .ignoresSafeArea()
                .accessibilityHidden(true)

            // Taps on the picture show and hide the controls; the buttons
            // above take their own taps first.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { model.toggleControls() }
                .accessibilityHidden(true)

            GeometryReader { proxy in
                let narrow = proxy.size.width < 560
                ZStack {
                    if model.controlsVisible || model.state.failureMessage != nil {
                        PlayerControlsOverlay(model: model, narrow: narrow)
                            .transition(.opacity)
                    } else if model.state == .buffering || model.state.isOpening {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                            .accessibilityLabel(Text("Loading"))
                    }
                    if let message = model.state.failureMessage {
                        PlayerErrorPanel(model: model, message: message)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.controlsVisible)
        .environment(\.colorScheme, .dark)
        .hearthStatusBarHidden()
        .persistentSystemOverlays(model.controlsVisible ? .automatic : .hidden)
        .onContinuousHover { phase in
            if case .active = phase { model.noteActivity() }
        }
        .focusable()
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            model.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard model.canSeek else { return .ignored }
            model.skip(by: -10)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard model.canSeek else { return .ignored }
            model.skip(by: 10)
            return .handled
        }
        .onKeyPress(.upArrow) {
            // Channel up is the next number, as on every remote (LIV-5).
            guard model.item.isLive, model.canGoToNextItem else { return .ignored }
            Task { await model.goToNextItem() }
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard model.item.isLive, model.canGoToPreviousItem else { return .ignored }
            Task { await model.goToPreviousItem() }
            return .handled
        }
        .onKeyPress(.escape) {
            model.close()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            return PlayerWindow.toggleFullScreen() ? .handled : .ignored
        }
        .onAppear { hasKeyboardFocus = true }
        .playerOrientationSupport()
        .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
            // Controls that fade can't be reached with VoiceOver.
            model.autoHidesControls = !enabled
        }
        .task { await model.start() }
    }
}

// MARK: - Controls

/// Everything drawn over the picture while the controls show.
struct PlayerControlsOverlay: View {
    let model: PlayerModel
    let narrow: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
                Spacer(minLength: 0)
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                PlayerTopBar(model: model, narrow: narrow)
                Spacer(minLength: 12)
                if model.state.failureMessage == nil {
                    PlayerCenterControls(model: model, narrow: narrow)
                }
                Spacer(minLength: 12)
                if model.state.failureMessage == nil {
                    PlayerBottomBar(model: model)
                }
            }
            .padding(.horizontal, narrow ? 16 : 24)
            .padding(.top, 18)
            .padding(.bottom, 12)
        }
    }
}

/// Close, the channel, its programme, then rotate (iPhone), tracks,
/// multi-view, PiP, AirPlay.
struct PlayerTopBar: View {
    let model: PlayerModel
    let narrow: Bool

    var body: some View {
        HStack(spacing: 14) {
            PlayerCircleButton(systemName: "xmark", label: "Close player") {
                model.close()
            }

            if !narrow, let logoName {
                ChannelLogo(name: logoName, url: model.item.logoURL, size: 40)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.item.title)
                    .font(.hearthDisplay(17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(.white)
                if let subtitle = model.item.subtitle {
                    Text(subtitle)
                        .font(.hearthText(13, relativeTo: .subheadline))
                        .foregroundStyle(PlayerPalette.secondaryText)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 6) {
                PlayerRotateButton(model: model)
                PlayerTracksMenu(model: model)
                if let keep = model.onKeepInBackground {
                    PlayerCircleButton(systemName: "arrow.down.right.and.arrow.up.left", label: "Keep playing in the background", action: keep)
                }
                if !narrow, let showMultiView = model.onShowMultiView {
                    PlayerCircleButton(systemName: "rectangle.grid.2x2", label: "Multi-view", action: showMultiView)
                }
                if model.supportsPictureInPicture {
                    PlayerCircleButton(systemName: "pip.enter", label: "Picture in picture") {
                        PlayerOrientationLock.shared.handBack()
                        model.startPictureInPicture()
                    }
                }
                AirPlayButton(player: model.airPlayPlayer)
            }
        }
    }

    /// The monogram's name: the channel's own, or for a channel item
    /// without one, its title.
    private var logoName: String? {
        model.item.channelName ?? (model.item.isLive ? model.item.title : nil)
    }
}

/// Audio, subtitles and picture size in one menu (PLY-6, PLY-7).
struct PlayerTracksMenu: View {
    let model: PlayerModel

    var body: some View {
        Menu {
            if !model.audioTracks.isEmpty {
                Section("Audio") {
                    Picker("Audio", selection: audioSelection) {
                        ForEach(Array(model.audioTracks.enumerated()), id: \.element.id) { index, track in
                            Text(track.displayName(index: index)).tag(Optional(track.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Section("Subtitles") {
                Picker("Subtitles", selection: subtitleSelection) {
                    Text("Off").tag(String?.none)
                    ForEach(Array(model.subtitleTracks.enumerated()), id: \.element.id) { index, track in
                        Text(track.displayName(index: index)).tag(Optional(track.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Picture") {
                Picker("Picture", selection: gravitySelection) {
                    ForEach(VideoGravity.allCases, id: \.self) { gravity in
                        Label(gravity.title, systemImage: gravity.systemImage).tag(gravity)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            PlayerCircleIcon(systemName: "captions.bubble")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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

/// −10 · play/pause · +10 (PLY-2).
struct PlayerCenterControls: View {
    let model: PlayerModel
    let narrow: Bool

    var body: some View {
        HStack(spacing: narrow ? 36 : 56) {
            PlayerCircleButton(systemName: "gobackward.10", label: "Back 10 seconds", diameter: 56, fill: .black.opacity(0.35), iconSize: 26) {
                model.skip(by: -10)
            }
            .disabled(!model.canSeek)
            .opacity(model.canSeek ? 1 : 0.35)

            centre

            PlayerCircleButton(systemName: "goforward.10", label: "Forward 10 seconds", diameter: 56, fill: .black.opacity(0.35), iconSize: 26) {
                model.skip(by: 10)
            }
            .disabled(!canSkipForward)
            .opacity(canSkipForward ? 1 : 0.35)
        }
        .overlay(alignment: .bottom) {
            if model.state == .buffering {
                ProgressView()
                    .tint(.white)
                    .offset(y: 40)
                    .accessibilityLabel(Text("Buffering"))
            }
        }
    }

    @ViewBuilder
    private var centre: some View {
        if model.state.isOpening {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(.black.opacity(0.45)))
                .accessibilityLabel(Text("Loading"))
        } else if model.state == .ended {
            PlayerCircleButton(systemName: "arrow.counterclockwise", label: "Play again", diameter: 72, fill: .black.opacity(0.45), iconSize: 28) {
                model.play()
            }
        } else {
            PlayerCircleButton(
                systemName: model.isPlaying ? "pause.fill" : "play.fill",
                label: model.isPlaying ? "Pause" : "Play",
                diameter: 72,
                fill: .black.opacity(0.45),
                iconSize: 28
            ) {
                model.togglePlayPause()
            }
        }
    }

    /// Nothing lies past the live edge.
    private var canSkipForward: Bool {
        model.canSeek && !(model.item.isLive && model.isAtLiveEdge)
    }
}

/// The offset badge and Jump to live, the scrub bar, its times and the
/// neighbouring channels' pills.
struct PlayerBottomBar: View {
    let model: PlayerModel

    var body: some View {
        let timeline = model.timeline
        VStack(alignment: .leading, spacing: 4) {
            if model.item.isLive {
                PlayerLiveStatusRow(model: model)
            }
            if timeline.showsBar {
                PlayerScrubBar(model: model, timeline: timeline)
            }
            HStack(spacing: 8) {
                Text(timeline.leadingLabel)
                    .font(.hearthMono(12, relativeTo: .caption))
                    .foregroundStyle(PlayerPalette.secondaryText)
                    .fixedSize()
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                if let previous = model.previousItemTitle {
                    PlayerPillButton(
                        title: "‹ " + previous,
                        accessibilityLabel: model.item.isLive
                            ? String(localized: "Previous channel, \(previous)")
                            : String(localized: "Previous, \(previous)")
                    ) {
                        Task { await model.goToPreviousItem() }
                    }
                }
                if let next = model.nextItemTitle {
                    PlayerPillButton(
                        title: next + " ›",
                        accessibilityLabel: model.item.isLive
                            ? String(localized: "Next channel, \(next)")
                            : String(localized: "Next, \(next)")
                    ) {
                        Task { await model.goToNextItem() }
                    }
                }
                Spacer(minLength: 8)
                Text(timeline.trailingLabel)
                    .font(.hearthMono(12, relativeTo: .caption))
                    .foregroundStyle(PlayerPalette.secondaryText)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .frame(minHeight: HearthMetrics.minimumHitTarget)
        }
    }
}

/// "−4:12  Paused live · catch-up from 19:30 … ● Jump to live", or LIVE
/// with "From the start" at the live edge (PLY-2, PLY-5).
struct PlayerLiveStatusRow: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 10) {
            if model.isAtLiveEdge {
                LiveBadge()
                if model.canPlayFromStart {
                    PlayerPillButton(title: String(localized: "From the start"), accessibilityLabel: String(localized: "Play from the start")) {
                        Task { await model.playFromStart() }
                    }
                }
            } else {
                Text(PlayerFormat.behindLive(model.liveOffset))
                    .font(.hearthMono(12, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PlayerPalette.badge))
                    .fixedSize()
                    .accessibilityLabel(Text("\(HearthFormat.timecode(model.liveOffset)) behind live"))
                Text(PlayerFormat.liveCaption(
                    isPaused: model.state == .paused,
                    catchUpFrom: model.item.hasArchive ? model.item.programmeStart : nil
                ))
                .font(.hearthText(13, relativeTo: .footnote))
                .foregroundStyle(PlayerPalette.secondaryText)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !model.isAtLiveEdge {
                JumpToLiveButton {
                    Task { await model.jumpToLive() }
                }
            }
        }
        .frame(minHeight: HearthMetrics.minimumHitTarget)
    }
}

/// The scrub bar (mockup 06): a white-22 % track, a lighter fill up to the
/// live edge, the amber fill and a white knob at the playhead. A touch jumps
/// the knob to the finger and a drag carries it (`ScrubDrag`: slower the
/// further the finger moves up away from the bar), with the time it points
/// at shown above it; the seek goes when the finger lifts — a seek behind
/// live may open the archive, which shouldn't happen on every pixel of a drag.
/// After it the knob stays on the target while the picture catches up
/// (`PlayerModel.pendingSeek`).
struct PlayerScrubBar: View {
    let model: PlayerModel
    let timeline: PlaybackTimeline
    @State private var drag: ScrubDrag?
    @State private var bubbleSize = CGSize(width: 70, height: 30)

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let position = drag?.fraction ?? timeline.position
            let isDragging = drag != nil
            let track: CGFloat = isDragging ? 8 : 4
            let knob: CGFloat = isDragging ? 26 : 16
            ZStack(alignment: .leading) {
                Capsule().fill(PlayerPalette.scrubTrack).frame(height: track)
                if let edge = timeline.liveEdge {
                    Capsule().fill(PlayerPalette.scrubLiveFill).frame(width: width * edge, height: track)
                }
                Capsule().fill(HearthColor.accent).frame(width: width * position, height: track)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(x: width * position - knob / 2)
            }
            .frame(width: width, height: proxy.size.height)
            .overlay(alignment: .topLeading) {
                if let drag {
                    ScrubPreviewBubble(time: timeline.label(forFraction: drag.fraction), speed: drag.speed.label)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
                        // Centred over the knob, kept inside the bar at its ends.
                        .offset(
                            x: min(max(width * drag.fraction - bubbleSize.width / 2, 0), max(width - bubbleSize.width, 0)),
                            y: -bubbleSize.height - 6
                        )
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isDragging)
            #if !os(tvOS)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if drag == nil {
                            drag = ScrubDrag(startX: value.startLocation.x, startY: value.startLocation.y, width: width, upperBound: timeline.liveEdge ?? 1)
                        }
                        drag?.move(toX: value.location.x, y: value.location.y)
                        model.showControls()
                    }
                    .onEnded { value in
                        drag?.move(toX: value.location.x, y: value.location.y)
                        let target = drag?.fraction ?? timeline.position
                        Task {
                            await model.seek(toFraction: target)
                            drag = nil
                        }
                    }
            )
            #endif
        }
        .frame(height: 44)
        .disabled(!model.canSeek)
        .accessibilityElement()
        .accessibilityLabel(Text(model.item.isLive ? "Playback position, live" : "Playback position"))
        .accessibilityValue(Text(timeline.positionLabel))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.skip(by: 10)
            case .decrement: model.skip(by: -10)
            @unknown default: break
            }
        }
    }
}

/// "23:41" above the knob while it's dragged, with the speed when slower.
struct ScrubPreviewBubble: View {
    let time: String
    let speed: String?

    var body: some View {
        VStack(spacing: 1) {
            Text(time)
                .font(.hearthMono(15, relativeTo: .callout))
                .foregroundStyle(.white)
            if let speed {
                Text(speed)
                    .font(.hearthText(11, relativeTo: .caption2))
                    .foregroundStyle(PlayerPalette.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.75)))
    }
}

// MARK: - Errors

/// The provider's or engine's message after the retry failed too (PLY-4),
/// with Retry and, when the owner has one, the same channel elsewhere.
struct PlayerErrorPanel: View {
    let model: PlayerModel
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(HearthColor.accent)
                .accessibilityHidden(true)
            Text(model.item.isLive ? "This channel couldn't play" : "This couldn't play")
                .font(.hearthDisplay(20, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(HearthColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.hearthText(15, relativeTo: .body))
                .foregroundStyle(HearthColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(spacing: 10) { buttons }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 440)
        .background(
            RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous)
                .fill(HearthColor.surface.opacity(0.95))
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Retry") {
            Task { await model.retry() }
        }
        .buttonStyle(.hearthPrimary)
        if let tryAnotherSource = model.onTryAnotherSource {
            Button("Try another source", action: tryAnotherSource)
                .buttonStyle(.hearthSecondary)
        }
    }
}
