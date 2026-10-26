import CatalogKit
import Core
import SwiftUI

/// What the guide has selected: a programme, or a channel's "No guide
/// information" cell (programme nil).
struct GuideSelection: Hashable {
    var channel: CatalogChannel
    var programme: CatalogProgramme?

    func isSelected(_ programme: CatalogProgramme?, on channel: CatalogChannel) -> Bool {
        self.channel.key == channel.key && self.programme?.id == programme?.id
    }
}

/// The guide's cell colours, read off LiveGuide.html. The aired and upcoming
/// outlines and the on-air outline are shades Core has no token for; they
/// stay here because nothing else draws them.
enum GuidePalette {
    static let airedFill = HearthColor.sidebar
    static let airedStroke = Color(hex: 0x1E2128)
    static let onAirFill = HearthColor.surfaceRaised
    static let onAirStroke = Color(hex: 0x343843)
    static let upcomingFill = HearthColor.surface
    static let upcomingStroke = Color(hex: 0x1E2128)
    static let cellRadius: CGFloat = 9
}

/// The timeline guide (LIV-2, mockup 03): channels down, pinned on the left;
/// time across, with a pinned header of half-hour ticks, the day menu and the
/// amber now marker; programme cells sized by duration.
///
/// One `ScrollView` scrolls both ways, so the header, the channel column and
/// every row share a single horizontal offset by construction. Rows are a
/// `LazyVStack`, so only those on screen exist (1,000 channels cost what a
/// screenful costs). The channel column and the header's day cell stay put
/// by offsetting themselves in `visualEffect` against their position in the
/// scroll view — geometry only, no body re-evaluation per frame — and the
/// header pins to the top as the stack's section header. Each row draws only
/// the programmes in the current `GuideWindow` (what's visible plus two
/// hours either side, snapped to the hour), which changes once per hour of
/// scrolling.
struct GuideGridView: View {
    let channels: [CatalogChannel]
    let timeline: GuideTimeline
    let metrics: GuideMetrics
    let now: Date
    let revision: Int
    let cache: GuideProgrammeCache
    let shortGuides: ShortGuideRequests
    @Binding var selection: GuideSelection?
    /// Room under the last row for the programme card.
    let bottomInset: CGFloat
    /// Changes with the chip, to scroll back to the first channel.
    let listID: String

    @Environment(CatalogService.self) private var catalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var position = ScrollPosition(point: .zero)
    @State private var snapshot: GuideScrollSnapshot?
    @State private var hasOpenedAtNow = false

    var body: some View {
        let window = snapshot?.window ?? .initial(now: now, in: timeline)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(channels) { channel in
                        GuideRow(
                            channel: channel,
                            window: window,
                            timeline: timeline,
                            metrics: metrics,
                            now: now,
                            revision: revision,
                            selectedProgrammeID: selectedID(on: channel),
                            cache: cache,
                            catalog: catalog
                        ) { programme in
                            select(programme, on: channel)
                        }
                        .onAppear { shortGuides.request(channel, catalog: catalog) }
                    }
                } header: {
                    GuideHeader(
                        timeline: timeline,
                        metrics: metrics,
                        window: window,
                        now: now,
                        visibleDay: GuideDay.containing(snapshot?.centreDate ?? now, now: now),
                        days: GuideDay.days(in: timeline, now: now)
                    ) { date in
                        jump(to: date)
                    }
                }
            }
            .frame(width: metrics.channelColumnWidth + timeline.totalWidth, alignment: .leading)
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden, axes: .horizontal)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        .overlay(alignment: nowSide == .before ? .topLeading : .topTrailing) {
            if nowSide != .visible, timeline.contains(now) {
                backToNowButton
            }
        }
        .onScrollGeometryChange(for: GuideScrollSnapshot.self) { geometry in
            GuideScrollSnapshot(geometry: geometry, timeline: timeline, metrics: metrics, now: now)
        } action: { _, new in
            snapshot = new
            if !hasOpenedAtNow, new.isLaidOut {
                hasOpenedAtNow = true
                scroll(toShow: now, animated: false)
            }
        }
        .onChange(of: TimelineAnchor(timeline)) { _, _ in
            // The guide grew a day at the front, or the scale changed with
            // the window's width: keep the same moment at the left edge.
            if let leading = snapshot?.leadingDate {
                position.scrollTo(x: max(0, timeline.x(for: leading)))
            }
        }
        .onChange(of: listID) { _, _ in
            position.scrollTo(y: 0)
        }
        .onDisappear { shortGuides.cancel() }
    }

    /// Where now is while the guide is scrolled away from it.
    private var nowSide: GuideSide {
        snapshot?.nowSide ?? .visible
    }

    /// "‹ Now" or "Now ›" under the header, pointing back at the now line
    /// once it has scrolled off screen.
    private var backToNowButton: some View {
        let isBefore = nowSide == .before
        return Button {
            jump(to: now)
        } label: {
            HStack(spacing: 4) {
                if isBefore { Image(systemName: "chevron.left") }
                Text("Now")
                if !isBefore { Image(systemName: "chevron.right") }
            }
        }
        .buttonStyle(.hearthPrimary(shape: .capsule, size: .small))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .padding(.top, metrics.headerHeight + 8)
        .padding(isBefore ? .leading : .trailing, isBefore ? metrics.channelColumnWidth + 8 : 12)
        .transition(.opacity)
        .accessibilityLabel(Text("Back to now"))
        .accessibilityHint(Text("Scrolls the guide to what's on now"))
    }

    private func selectedID(on channel: CatalogChannel) -> String?? {
        guard let selection, selection.channel.key == channel.key else { return nil }
        return .some(selection.programme?.id)
    }

    /// A tap raises the programme card; a tap on the selected cell puts it
    /// away again.
    private func select(_ programme: CatalogProgramme?, on channel: CatalogChannel) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            if let selection, selection.isSelected(programme, on: channel) {
                self.selection = nil
            } else {
                selection = GuideSelection(channel: channel, programme: programme)
            }
        }
    }

    private func jump(to date: Date) {
        scroll(toShow: date, animated: !reduceMotion)
    }

    private func scroll(toShow date: Date, animated: Bool) {
        let viewport = (snapshot?.viewportWidth ?? 0) - metrics.channelColumnWidth
        let x = timeline.scrollX(toShow: date, viewportWidth: max(viewport, 0))
        if animated {
            withAnimation(.snappy(duration: 0.35)) { position.scrollTo(x: x) }
        } else {
            position.scrollTo(x: x)
        }
    }
}

/// What the guide keeps from its scroll geometry, coarse enough that it
/// changes a few times an hour of scrolling rather than every frame.
struct GuideScrollSnapshot: Equatable {
    var window: GuideWindow
    /// The moment at the left edge of the timeline, to the quarter hour.
    var leadingDate: Date
    /// The moment in the middle of the screen, to the quarter hour: the day
    /// the header names, so opening at 00:10 with 23:30 at the edge still
    /// says "Today".
    var centreDate: Date
    var viewportWidth: CGFloat
    var isLaidOut: Bool
    /// Whether now is on screen, or which side it went off.
    var nowSide: GuideSide

    init(geometry: ScrollGeometry, timeline: GuideTimeline, metrics: GuideMetrics, now: Date) {
        let timelineViewport = geometry.containerSize.width - metrics.channelColumnWidth
        let offsetX = geometry.contentOffset.x
        window = .at(offsetX: offsetX, timelineViewport: timelineViewport, in: timeline)
        nowSide = timeline.side(of: now, offsetX: offsetX, viewportWidth: max(timelineViewport, 0))
        let leading = timeline.date(atX: offsetX)
        leadingDate = Date(timeIntervalSince1970: (leading.timeIntervalSince1970 / 900).rounded(.down) * 900)
        let centre = timeline.date(atX: offsetX + max(timelineViewport, 0) / 2)
        centreDate = Date(timeIntervalSince1970: (centre.timeIntervalSince1970 / 900).rounded(.down) * 900)
        viewportWidth = geometry.containerSize.width.rounded()
        isLaidOut = geometry.contentSize.width > geometry.containerSize.width && geometry.containerSize.width > 0
    }
}

/// The parts of a timeline whose change moves every x.
private struct TimelineAnchor: Equatable {
    var origin: Date
    var pointsPerMinute: CGFloat

    init(_ timeline: GuideTimeline) {
        origin = timeline.origin
        pointsPerMinute = timeline.pointsPerMinute
    }
}

// MARK: - Header

/// The pinned row above the channels: the day menu over the channel column,
/// half-hour ticks, and the amber now marker whose line the rows continue.
private struct GuideHeader: View {
    let timeline: GuideTimeline
    let metrics: GuideMetrics
    let window: GuideWindow
    let now: Date
    let visibleDay: GuideDay
    let days: [GuideDay]
    let onJump: (Date) -> Void

    var body: some View {
        let column = metrics.channelColumnWidth
        let ticks = GuideTick.ticks(in: window, timeline: timeline, now: timeline.contains(now) ? now : nil)
        let windowX = timeline.x(for: window.start)
        let windowWidth = timeline.x(for: window.end) - windowX
        ZStack(alignment: .topLeading) {
            HearthColor.background
                .frame(width: windowWidth, height: metrics.headerHeight)
                .offset(x: column + windowX)

            ForEach(ticks) { tick in
                Text(verbatim: tick.isDayStart ? tick.date.formatted(.dateTime.weekday(.abbreviated).day()) : HearthFormat.clock(tick.date))
                    .font(.hearthMono(11, weight: tick.isDayStart ? .semibold : .regular, relativeTo: .caption2))
                    .foregroundStyle(tick.isDayStart ? HearthColor.textPrimary : HearthColor.textSecondary)
                    .fixedSize()
                    .frame(height: metrics.headerHeight)
                    .offset(x: column + tick.x)
                    .accessibilityHidden(true)
            }

            if timeline.contains(now) {
                NowLineMarker(now, lineHeight: 0)
                    .position(x: column + timeline.x(for: now), y: metrics.headerHeight / 2)
            }

            dayMenu
                .frame(width: column, height: metrics.headerHeight, alignment: .leading)
                .background(HearthColor.background)
                .visualEffect { content, proxy in
                    content.offset(x: max(0, -proxy.frame(in: .scrollView).minX))
                }
                .accessibilitySortPriority(1)
        }
        .frame(width: column + timeline.totalWidth, height: metrics.headerHeight, alignment: .topLeading)
    }

    private var dayMenu: some View {
        Menu {
            Button {
                onJump(now)
            } label: {
                Label("Now", systemImage: "clock")
            }
            Divider()
            ForEach(days) { day in
                Button {
                    onJump(day.jumpTarget(now: now))
                } label: {
                    if day.start == visibleDay.start {
                        Label(day.title, systemImage: "checkmark")
                    } else {
                        Text(day.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(visibleDay.title)
                    .font(.hearthText(12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HearthColor.textTertiary)
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, minHeight: HearthMetrics.minimumHitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Day: \(visibleDay.spokenTitle)"))
        .accessibilityHint(Text("Jumps the guide to another day"))
    }
}

// MARK: - Row

/// One channel's row: its pinned logo and number, the programme cells in the
/// drawn window (or one "No guide information" cell), and its piece of the
/// now line.
private struct GuideRow: View {
    let channel: CatalogChannel
    let window: GuideWindow
    let timeline: GuideTimeline
    let metrics: GuideMetrics
    let now: Date
    let revision: Int
    /// nil: nothing in this row is selected; .some(nil): its no-guide cell.
    let selectedProgrammeID: String??
    let cache: GuideProgrammeCache
    let catalog: CatalogService
    let onSelect: (CatalogProgramme?) -> Void

    var body: some View {
        let programmes = cache.programmes(for: channel, in: window, catalog: catalog, revision: revision, now: now)
        let column = metrics.channelColumnWidth
        let windowX = timeline.x(for: window.start)
        let windowWidth = timeline.x(for: window.end) - windowX
        let cellY = (metrics.rowHeight - metrics.cellHeight) / 2
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(HearthColor.rowDivider)
                .frame(width: windowWidth, height: 1)
                .offset(x: column + windowX)
                .accessibilityHidden(true)

            if programmes.isEmpty {
                NoGuideCell(isSelected: selectedProgrammeID == .some(nil), leadingInset: column) {
                    onSelect(nil)
                }
                .frame(width: max(windowWidth - metrics.cellGap, 1), height: metrics.cellHeight)
                .offset(x: column + windowX, y: cellY)
            } else {
                ForEach(programmes) { programme in
                    if let frame = GuideCellFrame.make(start: programme.start, end: programme.end, window: window, timeline: timeline, gap: metrics.cellGap) {
                        ProgrammeCell(
                            programme: programme,
                            phase: .of(start: programme.start, end: programme.end, now: now),
                            isPlayable: CatchupRules.isPlayable(programme, on: channel, now: now),
                            isSelected: selectedProgrammeID == .some(programme.id),
                            now: now,
                            leadingInset: column
                        ) {
                            onSelect(programme)
                        }
                        .frame(width: frame.width, height: metrics.cellHeight)
                        .offset(x: column + frame.x, y: cellY)
                    }
                }
            }

            if timeline.contains(now) {
                Rectangle()
                    .fill(HearthColor.accent)
                    .frame(width: NowLineMarker.lineWidth, height: metrics.rowHeight)
                    .offset(x: column + timeline.x(for: now) - NowLineMarker.lineWidth / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            ChannelColumnCell(channel: channel, metrics: metrics)
                .frame(width: column, height: metrics.rowHeight)
                .background(HearthColor.background)
                .overlay(alignment: .top) {
                    Rectangle().fill(HearthColor.rowDivider).frame(height: 1).accessibilityHidden(true)
                }
                .visualEffect { content, proxy in
                    content.offset(x: max(0, -proxy.frame(in: .scrollView).minX))
                }
                .accessibilitySortPriority(1)
        }
        .frame(width: column + timeline.totalWidth, height: metrics.rowHeight, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// The pinned channel cell: logo and number (and name, where there's room).
/// Opens the channel's page.
private struct ChannelColumnCell: View {
    let channel: CatalogChannel
    let metrics: GuideMetrics

    var body: some View {
        NavigationLink(value: HearthRoute.channel(itemKey: channel.key.rawValue)) {
            HStack(spacing: 8) {
                ChannelLogo(name: channel.name, url: channel.logoURL, size: 34)
                if metrics.showsChannelNames {
                    VStack(alignment: .leading, spacing: 1) {
                        if let number = channel.number {
                            Text(verbatim: String(number))
                                .font(.hearthMono(11, relativeTo: .caption2))
                                .foregroundStyle(HearthColor.textSecondary)
                        }
                        Text(channel.name)
                            .font(.hearthText(13, weight: .medium, relativeTo: .footnote))
                            .foregroundStyle(HearthColor.textPrimary)
                            .lineLimit(1)
                    }
                } else if let number = channel.number {
                    Text(verbatim: String(number))
                        .font(.hearthMono(11, relativeTo: .caption2))
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ChannelText.numberedName(number: channel.number, name: channel.name)))
        .accessibilityHint(Text("Opens the channel"))
    }
}

/// A programme in the guide: title and mono times, a catch-up mark on aired
/// programmes the archive still has (LIV-4), on-air cells raised, the
/// selected one outlined in amber. A programme that started off screen keeps
/// its title in view by sliding it right, out from under the channel column.
private struct ProgrammeCell: View {
    let programme: CatalogProgramme
    let phase: ProgrammePhase
    let isPlayable: Bool
    let isSelected: Bool
    let now: Date
    let leadingInset: CGFloat
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GuidePalette.cellRadius, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if phase == .aired && isPlayable {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                    Text(programme.title)
                        .font(.hearthText(12.5, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(phase == .aired ? HearthColor.textSecondary : HearthColor.textPrimary)
                }
                Text(verbatim: HearthFormat.compactTimeRange(programme.start, programme.end))
                    .font(.hearthMono(10, relativeTo: .caption2))
                    .foregroundStyle(HearthColor.textTertiary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .visualEffect { content, proxy in
                let hidden = leadingInset - proxy.frame(in: .scrollView).minX
                let room = max(0, proxy.size.width - 90)
                return content.offset(x: min(max(0, hidden), room))
            }
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(isSelected ? HearthColor.accent : stroke, lineWidth: 1.5))
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ProgrammeText.spokenCell(title: programme.title, start: programme.start, end: programme.end, now: now, isPlayable: phase != .upcoming && isPlayable)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("Shows the programme's details"))
    }

    private var fill: Color {
        switch phase {
        case .aired: GuidePalette.airedFill
        case .onAir: GuidePalette.onAirFill
        case .upcoming: GuidePalette.upcomingFill
        }
    }

    private var stroke: Color {
        switch phase {
        case .aired: GuidePalette.airedStroke
        case .onAir: GuidePalette.onAirStroke
        case .upcoming: GuidePalette.upcomingStroke
        }
    }
}

/// The single wide cell of a channel with no programmes in view.
private struct NoGuideCell: View {
    let isSelected: Bool
    let leadingInset: CGFloat
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GuidePalette.cellRadius, style: .continuous)
        Button(action: action) {
            Text("No guide information")
                .font(.hearthText(12.5, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(HearthColor.textTertiary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .visualEffect { content, proxy in
                    let hidden = leadingInset - proxy.frame(in: .scrollView).minX
                    let room = max(0, proxy.size.width - 180)
                    return content.offset(x: min(max(0, hidden), room))
                }
                .background(shape.fill(GuidePalette.upcomingFill))
                .overlay(shape.strokeBorder(isSelected ? HearthColor.accent : GuidePalette.upcomingStroke, lineWidth: 1.5))
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("No guide information"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("Shows the channel's details"))
    }
}
