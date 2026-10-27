import CatalogKit
import Core
import SwiftUI

/// The Live TV guide on the Apple TV (LIV-1, LIV-2, LIV-4, LIV-5; mockup 03
/// at ten feet), built for the focus engine rather than for scrolling.
///
/// The categories run across the top. Below them a panel describes whatever
/// programme has focus, then a ruler of half-hour ticks over three hours, then
/// one row per channel (lazy: a portal's thousands cost a screenful). Every
/// programme cell is a button sized by its duration — select watches it:
/// live when it is on, from the archive when it aired and the archive has it
/// (LIV-4), the channel live when it is still to come. Press and hold for
/// From the start, the channel's page and favorites.
///
/// Time moves in pages rather than by scrolling: each row ends in an
/// invisible focus target on either side, and moving onto one (a swipe or a
/// click past the first or last cell) shifts the three hours back or on and
/// puts focus on the programme before or after. "Now" in the ruler comes
/// back to the present.
struct TVLiveGuide: View {
    let chips: [LiveChip]
    let chip: LiveChip
    let channels: [CatalogChannel]
    let favoriteKeys: Set<String>
    let guideRange: ClosedRange<Date>?
    let isLoaded: Bool
    let now: Date
    let revision: Int
    let cache: GuideProgrammeCache
    let shortGuides: ShortGuideRequests
    let keepsFavorites: Bool
    let emptyMessage: TVGuideEmptyMessage?
    let onSelectChip: (LiveChip) -> Void
    let onToggleFavorite: (CatalogChannel) -> Void
    let onPlay: (ProgrammeAction, CatalogChannel, CatalogProgramme?) -> Void

    @Environment(CatalogService.self) private var catalog
    @Environment(\.openRoute) private var openRoute

    /// The window's start once paged; nil follows now.
    @State private var pagedStart: Date?
    @FocusState private var focus: TVGuideFocus?
    /// The programme cell focused last, for moving one programme on or back
    /// when an edge is reached.
    @State private var lastCell: TVGuideFocus?

    static let windowLength: TimeInterval = 3 * 3600
    static let channelColumnWidth: CGFloat = 330
    static let rowHeight: CGFloat = 104
    static let edgeWidth: CGFloat = 14

    private var timeline: GuideTimeline {
        GuideTimeline.make(guideRange: guideRange, now: now, pointsPerMinute: 1)
    }

    private var window: GuideWindow {
        let start = pagedStart ?? TVGuidePaging.halfHour(containing: now)
        return GuideWindow(start: start, end: start.addingTimeInterval(Self.windowLength))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            chipRow
            if !isLoaded {
                Spacer()
            } else if channels.isEmpty {
                emptyState
                Spacer()
            } else {
                TVGuideInfoPanel(focused: focusedProgramme, now: now)
                GeometryReader { proxy in
                    let timelineWidth = max(proxy.size.width - Self.channelColumnWidth - 2 * Self.edgeWidth, 300)
                    let pointsPerMinute = timelineWidth / CGFloat(Self.windowLength / 60)
                    VStack(alignment: .leading, spacing: 0) {
                        ruler(timelineWidth: timelineWidth, pointsPerMinute: pointsPerMinute)
                        grid(timelineWidth: timelineWidth, pointsPerMinute: pointsPerMinute)
                    }
                }
            }
        }
        .onChange(of: focus) { _, newValue in
            handleFocus(newValue)
        }
        .onChange(of: chip) { _, _ in
            pagedStart = nil
        }
    }

    // MARK: Categories

    private var chipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(chips) { item in
                    Button(item.title) {
                        onSelectChip(item)
                    }
                    .buttonStyle(.hearthTV(isSelected: item == chip))
                    .accessibilityAddTraits(item == chip ? .isSelected : [])
                }
            }
            .padding(.vertical, 18)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .hearthFocusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Categories"))
    }

    // MARK: Ruler

    /// The day, Earlier / Now / Later, and the half-hour ticks with the now
    /// marker.
    private func ruler(timelineWidth: CGFloat, pointsPerMinute: CGFloat) -> some View {
        let window = window
        let ticks = stride(from: window.start.timeIntervalSince1970, to: window.end.timeIntervalSince1970, by: 1800).map(Date.init(timeIntervalSince1970:))
        return HStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    page(by: -3600)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.hearthTV)
                .disabled(window.start <= timeline.origin)
                .accessibilityLabel(Text("Earlier"))
                Button {
                    pagedStart = nil
                } label: {
                    Text(GuideDay.containing(window.start, now: now).isToday ? String(localized: "Now") : GuideDay.containing(window.start, now: now).title)
                }
                .buttonStyle(.hearthTV(isSelected: pagedStart == nil))
                .accessibilityLabel(Text("Back to now"))
                Button {
                    page(by: 3600)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.hearthTV)
                .disabled(window.end >= timeline.end)
                .accessibilityLabel(Text("Later"))
            }
            .frame(width: Self.channelColumnWidth + Self.edgeWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                ForEach(ticks, id: \.self) { tick in
                    Text(verbatim: HearthFormat.clock(tick))
                        .font(.hearthTVMono)
                        .foregroundStyle(HearthColor.textSecondary)
                        .fixedSize()
                        .offset(x: CGFloat(tick.timeIntervalSince(window.start) / 60) * pointsPerMinute)
                }
                if window.start <= now, now < window.end {
                    Capsule()
                        .fill(HearthColor.accent)
                        .frame(width: 6, height: 30)
                        .offset(x: CGFloat(now.timeIntervalSince(window.start) / 60) * pointsPerMinute - 3)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: timelineWidth, alignment: .leading)
            .accessibilityHidden(true)
        }
        .padding(.bottom, 14)
        .hearthFocusSection()
    }

    // MARK: Rows

    private func grid(timelineWidth: CGFloat, pointsPerMinute: CGFloat) -> some View {
        let window = window
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(channels) { channel in
                    TVGuideRow(
                        channel: channel,
                        programmes: cache.programmes(for: channel, from: window.start, to: window.end, catalog: catalog, revision: revision, now: now),
                        window: window,
                        timelineWidth: timelineWidth,
                        pointsPerMinute: pointsPerMinute,
                        now: now,
                        isFavorite: favoriteKeys.contains(channel.key.rawValue),
                        keepsFavorites: keepsFavorites,
                        focus: $focus,
                        onPlay: { action, programme in onPlay(action, channel, programme) },
                        onToggleFavorite: { onToggleFavorite(channel) },
                        onOpenChannel: { openRoute(.channel(itemKey: channel.key.rawValue)) }
                    )
                    .onAppear { shortGuides.request(channel, catalog: catalog) }
                    .id(channel.key)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollClipDisabled()
        .defaultFocus($focus, initialFocus)
        .onDisappear { shortGuides.cancel() }
    }

    /// The first channel's programme on now (or its no-guide cell).
    private var initialFocus: TVGuideFocus? {
        guard let first = channels.first else { return nil }
        let programmes = cache.programmes(for: first, from: window.start, to: window.end, catalog: catalog, revision: revision, now: now)
        let current = programmes.first { $0.isOn(at: now) } ?? programmes.first
        return .cell(channel: first.key.rawValue, programme: current?.id)
    }

    // MARK: Focus and paging

    /// The programme the info panel describes: what has focus, what had it
    /// last, or before anything has, the first channel's programme on now.
    private var focusedProgramme: TVGuideFocused? {
        guard case .cell(let key, let programmeID) = focus ?? lastCell ?? initialFocus,
              let channel = channels.first(where: { $0.key.rawValue == key }) else { return nil }
        let programme = programmeID.flatMap { id in
            cache.programmes(for: channel, from: window.start.addingTimeInterval(-6 * 3600), to: window.end.addingTimeInterval(6 * 3600), catalog: catalog, revision: revision, now: now)
                .first { $0.id == id }
        }
        return TVGuideFocused(channel: channel, programme: programme)
    }

    private func page(by seconds: TimeInterval) {
        let start = TVGuidePaging.clampedStart(window.start.addingTimeInterval(seconds), length: Self.windowLength, origin: timeline.origin, end: timeline.end)
        pagedStart = TVGuidePaging.halfHour(containing: now) == start ? nil : start
    }

    /// A row's edge took focus: page, then focus the programme beyond.
    private func handleFocus(_ newValue: TVGuideFocus?) {
        switch newValue {
        case .cell:
            lastCell = newValue
        case .leadingEdge(let key):
            move(in: key, forward: false)
        case .trailingEdge(let key):
            move(in: key, forward: true)
        case nil:
            break
        }
    }

    private func move(in key: String, forward: Bool) {
        guard let channel = channels.first(where: { $0.key.rawValue == key }) else { return }
        let current = window
        let from: CatalogProgramme? = {
            guard case .cell(let lastKey, let id?) = lastCell, lastKey == key else { return nil }
            return cache.programmes(for: channel, from: current.start.addingTimeInterval(-6 * 3600), to: current.end.addingTimeInterval(6 * 3600), catalog: catalog, revision: revision, now: now)
                .first { $0.id == id }
        }()
        let wide = cache.programmes(
            for: channel,
            from: current.start.addingTimeInterval(forward ? 0 : -12 * 3600),
            to: current.end.addingTimeInterval(forward ? 12 * 3600 : 0),
            catalog: catalog, revision: revision, now: now
        )
        let target = TVGuidePaging.neighbour(of: from, in: wide, windowStart: current.start, windowEnd: current.end, forward: forward)
        let start = TVGuidePaging.pagedStart(
            from: current.start, length: Self.windowLength, forward: forward, toShow: target,
            origin: timeline.origin, end: timeline.end
        )
        pagedStart = TVGuidePaging.halfHour(containing: now) == start ? nil : start
        let next: TVGuideFocus = .cell(channel: key, programme: target?.id ?? (wide.isEmpty ? nil : from?.id))
        // Once the rows have redrawn for the new window and the focus engine
        // has settled on the edge's neighbour.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            focus = next
        }
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if let emptyMessage {
            VStack(alignment: .leading, spacing: 28) {
                TVNoticeCard(systemName: emptyMessage.systemName, title: emptyMessage.title, message: emptyMessage.message)
                if let action = emptyMessage.actionTitle, let perform = emptyMessage.action {
                    Button(action, action: perform)
                        .buttonStyle(.hearthTV(isProminent: true))
                }
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(.top, 40)
        }
    }
}

/// What the guide says when a chip has no channels.
struct TVGuideEmptyMessage {
    var systemName: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?
}

/// Where focus is in the guide.
enum TVGuideFocus: Hashable {
    /// A programme cell; a nil programme is the row's "No guide" cell.
    case cell(channel: String, programme: String?)
    case leadingEdge(channel: String)
    case trailingEdge(channel: String)
}

/// The focused programme and its channel, for the info panel.
struct TVGuideFocused {
    var channel: CatalogChannel
    var programme: CatalogProgramme?
}

/// The guide's paging, as values (no views), so it can be tested.
enum TVGuidePaging {
    /// The half hour `date` falls in: the guide's pages start on one.
    static func halfHour(containing date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
    }

    static func clampedStart(_ start: Date, length: TimeInterval, origin: Date, end: Date) -> Date {
        let latest = max(origin, end.addingTimeInterval(-length))
        return min(max(halfHour(containing: start), origin), latest)
    }

    /// The programme after (or before) `from` in `programmes`; with no
    /// `from`, the first one starting at the window's end (or the last one
    /// ending at its start).
    static func neighbour(of from: CatalogProgramme?, in programmes: [CatalogProgramme], windowStart: Date, windowEnd: Date, forward: Bool) -> CatalogProgramme? {
        let sorted = programmes.sorted { $0.start < $1.start }
        if forward {
            let after = from?.end ?? windowEnd
            return sorted.first { $0.start >= after.addingTimeInterval(-1) && $0.id != from?.id }
        } else {
            let before = from?.start ?? windowStart
            return sorted.last { $0.end <= before.addingTimeInterval(1) && $0.id != from?.id }
        }
    }

    /// The next page's start: an hour on or back, and further when the
    /// target programme is still outside it.
    static func pagedStart(from start: Date, length: TimeInterval, forward: Bool, toShow target: CatalogProgramme?, origin: Date, end: Date) -> Date {
        var next = start
        for _ in 0..<48 {
            next = clampedStart(next.addingTimeInterval(forward ? 3600 : -3600), length: length, origin: origin, end: end)
            guard let target else { break }
            let windowEnd = next.addingTimeInterval(length)
            let visible = forward ? target.start < windowEnd : target.end > next
            if visible || next <= origin || windowEnd >= end { break }
        }
        return next
    }
}

// MARK: - Info panel

/// What has focus: the programme's title, its channel, time and how long is
/// left, and its summary.
private struct TVGuideInfoPanel: View {
    let focused: TVGuideFocused?
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            if let focused {
                ChannelLogo(name: focused.channel.name, url: focused.channel.logoURL, size: 96)
                VStack(alignment: .leading, spacing: 8) {
                    Text(focused.programme?.title ?? focused.channel.name)
                        .font(.hearthTVTitle)
                        .tracking(-0.5)
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                    Text(ProgrammeText.cardSubtitle(
                        channelNumber: focused.channel.number,
                        channelName: focused.channel.name,
                        start: focused.programme?.start,
                        end: focused.programme?.end,
                        now: now
                    ))
                    .font(.hearthTVCallout)
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineLimit(1)
                    if let summary = focused.programme?.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.hearthTVCaption)
                            .foregroundStyle(HearthColor.textTertiary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 170, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

private struct TVGuideRow: View {
    let channel: CatalogChannel
    let programmes: [CatalogProgramme]
    let window: GuideWindow
    let timelineWidth: CGFloat
    let pointsPerMinute: CGFloat
    let now: Date
    let isFavorite: Bool
    let keepsFavorites: Bool
    var focus: FocusState<TVGuideFocus?>.Binding
    let onPlay: (ProgrammeAction, CatalogProgramme?) -> Void
    let onToggleFavorite: () -> Void
    let onOpenChannel: () -> Void

    private static let gap: CGFloat = 8

    var body: some View {
        HStack(spacing: 0) {
            channelCell
                .frame(width: TVLiveGuide.channelColumnWidth, alignment: .leading)
            edge(.leadingEdge(channel: key))
            programmeStrip
                .frame(width: timelineWidth, height: TVLiveGuide.rowHeight - 14, alignment: .leading)
                .overlay(alignment: .leading) { nowLine }
            edge(.trailingEdge(channel: key))
        }
        .frame(height: TVLiveGuide.rowHeight)
        .hearthFocusSection()
    }

    private var key: String { channel.key.rawValue }

    private var channelCell: some View {
        HStack(spacing: 18) {
            ChannelLogo(name: channel.name, url: channel.logoURL, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                if let number = channel.number {
                    Text(verbatim: String(number))
                        .font(.hearthTVMono)
                        .foregroundStyle(HearthColor.textTertiary)
                }
                Text(channel.name)
                    .font(.hearthText(24, weight: .semibold, relativeTo: .callout))
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HearthColor.accent)
                    .accessibilityLabel(Text("Favorite"))
            }
        }
        .padding(.trailing, 20)
        .accessibilityElement(children: .combine)
    }

    /// The cells in the window, laid out left to right with the gaps between
    /// them as space (no offsets, so the focus engine sees where each is).
    @ViewBuilder
    private var programmeStrip: some View {
        if programmes.isEmpty {
            cell(programme: nil, width: timelineWidth - Self.gap)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(layout.enumerated()), id: \.element.programme.id) { _, item in
                    Color.clear.frame(width: item.leadingSpace)
                    cell(programme: item.programme, width: item.width)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct Placed {
        var programme: CatalogProgramme
        var leadingSpace: CGFloat
        var width: CGFloat
    }

    /// Each programme clipped to the window, as the space before it and its
    /// width; the gap between neighbours is the last few points of each slot.
    private var layout: [Placed] {
        var placed: [Placed] = []
        var cursor: CGFloat = 0
        for programme in programmes.sorted(by: { $0.start < $1.start }) {
            let start = max(programme.start, window.start)
            let end = min(programme.end, window.end)
            guard end > start else { continue }
            let x = CGFloat(start.timeIntervalSince(window.start) / 60) * pointsPerMinute
            let slot = CGFloat(end.timeIntervalSince(start) / 60) * pointsPerMinute
            let leading = max(0, x - cursor)
            let width = max(slot - Self.gap, 12)
            placed.append(Placed(programme: programme, leadingSpace: leading, width: width))
            cursor += leading + width
        }
        return placed
    }

    private func cell(programme: CatalogProgramme?, width: CGFloat) -> some View {
        let phase = programme.map { ProgrammePhase.of(start: $0.start, end: $0.end, now: now) }
        let playable = programme.map { CatchupRules.isPlayable($0, on: channel, now: now) } ?? false
        let actions = ProgrammeActions.make(phase: phase, channelHasArchive: channel.hasArchive, isPlayable: playable)
        return Button {
            onPlay(selectAction(phase: phase, actions: actions), programme)
        } label: {
            TVProgrammeCellLabel(programme: programme, phase: phase, isPlayable: playable, width: width)
        }
        .buttonStyle(TVProgrammeCellStyle(phase: phase))
        .frame(width: width)
        .focused(focus, equals: .cell(channel: key, programme: programme?.id))
        .contextMenu {
            if let primary = actions.primary {
                Button {
                    onPlay(primary, programme)
                } label: {
                    Label(primary.title, systemImage: primary.systemImage)
                }
            }
            if let secondary = actions.secondary {
                Button {
                    onPlay(secondary, programme)
                } label: {
                    Label(secondary.title, systemImage: secondary.systemImage)
                }
            }
            if phase == .upcoming {
                Button {
                    onPlay(.watchLive, nil)
                } label: {
                    Label(String(localized: "Watch \(channel.name) live"), systemImage: "play.fill")
                }
            }
            Button(action: onOpenChannel) {
                Label(String(localized: "Open channel"), systemImage: "tv")
            }
            if keepsFavorites {
                Button(action: onToggleFavorite) {
                    if isFavorite {
                        Label(String(localized: "Unfavorite"), systemImage: "heart.slash")
                    } else {
                        Label(String(localized: "Favorite"), systemImage: "heart")
                    }
                }
            }
        }
        .accessibilityLabel(Text(programme.map {
            ProgrammeText.spokenCell(title: $0.title, start: $0.start, end: $0.end, now: now, isPlayable: phase != .upcoming && playable)
        } ?? String(localized: "No guide information")))
        .accessibilityHint(Text("Plays it"))
    }

    /// Select: live when on (or nothing known), the archive when aired and
    /// playable, otherwise the channel live.
    private func selectAction(phase: ProgrammePhase?, actions: ProgrammeActions) -> ProgrammeAction {
        if phase == .aired, actions.primary == .playFromStart { return .playFromStart }
        return .watchLive
    }

    /// A thin target the remote can land on past the first or last cell; it
    /// draws nothing and hands focus straight back (TVLiveGuide pages).
    private func edge(_ value: TVGuideFocus) -> some View {
        Button {} label: {
            Color.clear.frame(width: TVLiveGuide.edgeWidth, height: TVLiveGuide.rowHeight - 14)
        }
        .buttonStyle(TVInvisibleStyle())
        .focused(focus, equals: value)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var nowLine: some View {
        if window.start <= now, now < window.end {
            Rectangle()
                .fill(HearthColor.accent)
                .frame(width: 3, height: TVLiveGuide.rowHeight)
                .offset(x: CGFloat(now.timeIntervalSince(window.start) / 60) * pointsPerMinute - 1.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A cell's words: title, times, the catch-up mark.
private struct TVProgrammeCellLabel: View {
    let programme: CatalogProgramme?
    let phase: ProgrammePhase?
    let isPlayable: Bool
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if phase == .aired && isPlayable {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 18, weight: .semibold))
                }
                Text(programme?.title ?? String(localized: "No guide information"))
                    .font(.hearthText(23, weight: .semibold, relativeTo: .callout))
            }
            if let programme, width > 150 {
                Text(verbatim: HearthFormat.compactTimeRange(programme.start, programme.end))
                    .font(.hearthMono(18, relativeTo: .caption))
                    .opacity(0.75)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, width > 60 ? 18 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The cell's fill by phase (aired darker, on-air raised); amber with dark
/// ink under focus, and a touch larger.
private struct TVProgrammeCellStyle: ButtonStyle {
    let phase: ProgrammePhase?

    func makeBody(configuration: Configuration) -> some View {
        TVProgrammeCellBody(configuration: configuration, phase: phase)
    }
}

private struct TVProgrammeCellBody: View {
    let configuration: ButtonStyleConfiguration
    let phase: ProgrammePhase?
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .foregroundStyle(foreground)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(isFocused ? Color.clear : stroke, lineWidth: 1.5))
            .clipShape(shape)
            .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 14, y: 8)
            .zIndex(isFocused ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isFocused)
    }

    private var foreground: Color {
        if isFocused { return HearthColor.onAccent }
        return phase == .aired ? HearthColor.textSecondary : HearthColor.textPrimary
    }

    private var fill: Color {
        if isFocused { return HearthColor.accent }
        switch phase {
        case .aired: return GuidePalette.airedFill
        case .onAir: return GuidePalette.onAirFill
        case .upcoming, nil: return GuidePalette.upcomingFill
        }
    }

    private var stroke: Color {
        switch phase {
        case .aired: GuidePalette.airedStroke
        case .onAir: GuidePalette.onAirStroke
        case .upcoming, nil: GuidePalette.upcomingStroke
        }
    }
}

/// Draws the label only, focused or not: the rows' edges.
private struct TVInvisibleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
