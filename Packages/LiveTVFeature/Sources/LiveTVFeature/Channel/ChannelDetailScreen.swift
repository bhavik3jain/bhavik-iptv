import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// A channel's page (`HearthRoute.channel`): its logo, number, name and
/// source, what's on now with Watch live, From the start (an archive
/// channel, LIV-4) and the heart (FAV-1, hidden for a Guest); then the day's
/// programmes, with catch-up marks on the aired ones the archive still has.
/// A day row moves across the days the guide holds. Aired programmes in the
/// archive play from their start; the one on now plays live.
///
/// One readable column, centred where the screen is wide (iPad, Mac, iPhone
/// Duo opened); the guide's channel cell and search open it.
struct ChannelDetailScreen: View {
    let itemKey: ItemKey

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout
    @Environment(\.play) private var play

    @State private var channel: CatalogChannel?
    @State private var isLoaded = false
    @State private var days: [GuideDay] = []
    /// Midnight of the day shown; nil for today.
    @State private var selectedDayStart: Date?
    @State private var programmes: [CatalogProgramme] = []

    private var profileID: UUID? { session.currentProfile?.id }
    private var keepsFavorites: Bool { profileID != nil && !session.isGuest }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .hearthScreenBackground()
        .navigationTitle(Text(channel?.name ?? String(localized: "Channel")))
        .inlineNavigationTitle()
        .task(id: LoadKey(itemKey: itemKey, revision: catalog.revision, profileID: profileID, day: selectedDayStart)) {
            load(now: .now)
        }
        .task(id: channel?.key) {
            // Stalker has no full guide: ask for this channel's.
            if let channel { await catalog.loadShortGuide(for: [channel]) }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let channel {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: HearthMetrics.sectionSpacing) {
                        header(channel, now: now)
                        dayRow(now: now)
                        programmeList(channel, now: now)
                    }
                    .padding(.horizontal, layout == .compact ? 20 : 28)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: programmes) { _, _ in
                    scrollToCurrent(reader, now: now)
                }
                .onAppear { scrollToCurrent(reader, now: now) }
            }
        } else if isLoaded {
            EmptyStateView(
                systemName: "tv.slash",
                title: String(localized: "Channel not available"),
                message: String(localized: "The provider may have removed it, or it's hidden for this profile.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    // MARK: Header

    private func header(_ channel: CatalogChannel, now: Date) -> some View {
        let current = programmes.first(where: { $0.isOn(at: now) }) ?? catalog.nowAndNext(for: channel, at: now).now
        let isFavorite = isFavorite(channel)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ChannelLogo(name: channel.name, url: channel.logoURL, size: layout == .compact ? 64 : 76)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let number = channel.number {
                            Text(verbatim: String(number))
                                .font(.hearthMono(13, weight: .medium, relativeTo: .footnote))
                                .foregroundStyle(HearthColor.textSecondary)
                        }
                        if let source = SourceLabel.name(for: channel, catalog: catalog) {
                            Text(source)
                                .font(.hearthCaption)
                                .foregroundStyle(HearthColor.textTertiary)
                                .lineLimit(1)
                        }
                        if channel.hasArchive {
                            StatusChip(String(localized: "Catch-up"), systemImage: "arrow.counterclockwise")
                        }
                    }
                    Text(channel.name)
                        .font(.hearthTitle)
                        .tracking(HearthMetrics.titleTracking)
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if keepsFavorites {
                    FavoriteHeartButton(isFavorite: isFavorite, fill: HearthColor.surface) {
                        if let profileID {
                            store.toggleFavorite(profileID: profileID, itemKey: channel.key.rawValue, kind: .channel)
                        }
                    }
                }
            }

            if let current {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        LiveBadge()
                        Text(current.title)
                            .font(.hearthHeadline)
                            .foregroundStyle(HearthColor.textPrimary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        HearthProgressBar(value: current.progress(at: now), height: 4)
                        Text(verbatim: HearthFormat.remaining(current.end.timeIntervalSince(now)))
                            .font(.hearthMono(12, relativeTo: .caption))
                            .foregroundStyle(HearthColor.textSecondary)
                            .layoutPriority(1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(ProgrammeText.spokenCell(title: current.title, start: current.start, end: current.end, now: now, isPlayable: false)))
            }

            buttons(channel, current: current, now: now)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous)
                .fill(HearthColor.surface)
        )
    }

    private func isFavorite(_ channel: CatalogChannel) -> Bool {
        // Reading the store's revision redraws the heart after a toggle here
        // or on another device; the query itself isn't observable.
        _ = store.revision
        guard let profileID else { return false }
        return store.isFavorite(profileID: profileID, itemKey: channel.key.rawValue)
    }

    private func buttons(_ channel: CatalogChannel, current: CatalogProgramme?, now: Date) -> some View {
        let actions = ProgrammeActions.make(phase: current == nil ? nil : .onAir, channelHasArchive: channel.hasArchive, isPlayable: true)
        return HStack(spacing: 10) {
            Button {
                perform(.watchLive, channel: channel, programme: current, now: now)
            } label: {
                Label(ProgrammeAction.watchLive.title, systemImage: ProgrammeAction.watchLive.systemImage)
                    .frame(maxWidth: layout == .compact ? .infinity : nil)
            }
            .buttonStyle(.hearthPrimary(shape: .rounded, size: .regular))
            .accessibilityHint(Text("Plays the channel live"))

            if actions.secondary == .fromTheStart, let current {
                Button {
                    perform(.fromTheStart, channel: channel, programme: current, now: now)
                } label: {
                    Label(ProgrammeAction.fromTheStart.title, systemImage: ProgrammeAction.fromTheStart.systemImage)
                        .frame(maxWidth: layout == .compact ? .infinity : nil)
                }
                .buttonStyle(.hearthSecondary(shape: .rounded, size: .regular))
                .accessibilityHint(Text("Plays the programme on now from its start"))
            }
        }
    }

    // MARK: Days

    @ViewBuilder
    private func dayRow(now: Date) -> some View {
        if days.count > 1 {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(days) { day in
                            PillChip(day.title, isSelected: isSelected(day)) {
                                selectedDayStart = day.isToday ? nil : day.start
                            }
                            .accessibilityLabel(Text(day.spokenTitle))
                            .id(day.start)
                        }
                    }
                    .padding(.horizontal, layout == .compact ? 20 : 28)
                }
                .padding(.horizontal, layout == .compact ? -20 : -28)
                .onAppear {
                    if let today = days.first(where: \.isToday) {
                        reader.scrollTo(today.start, anchor: .center)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Days"))
        }
    }

    private func isSelected(_ day: GuideDay) -> Bool {
        selectedDayStart.map { $0 == day.start } ?? day.isToday
    }

    // MARK: Programmes

    @ViewBuilder
    private func programmeList(_ channel: CatalogChannel, now: Date) -> some View {
        if programmes.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 20))
                    .foregroundStyle(HearthColor.glyphMuted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No guide information")
                        .font(.hearthBody)
                        .foregroundStyle(HearthColor.textPrimary)
                    Text("The provider hasn't sent this channel's programmes for this day.")
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous).fill(HearthColor.surface))
            .accessibilityElement(children: .combine)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(programmes) { programme in
                    ChannelProgrammeRow(
                        programme: programme,
                        phase: .of(start: programme.start, end: programme.end, now: now),
                        isPlayable: CatchupRules.isPlayable(programme, on: channel, now: now),
                        now: now
                    ) { action in
                        perform(action, channel: channel, programme: programme, now: now)
                    }
                    .id(programme.id)
                    if programme.id != programmes.last?.id {
                        RowDivider(leadingInset: 76)
                    }
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: HearthMetrics.groupedCardRadius, style: .continuous).fill(HearthColor.surface))
        }
    }

    private func scrollToCurrent(_ reader: ScrollViewProxy, now: Date) {
        guard selectedDayStart == nil, let current = programmes.first(where: { $0.isOn(at: now) }) else { return }
        reader.scrollTo(current.id, anchor: .center)
    }

    // MARK: Loading and actions

    private func load(now: Date) {
        channel = catalog.channel(itemKey)
        isLoaded = true
        guard let channel else {
            programmes = []
            return
        }
        let timeline = GuideTimeline.make(guideRange: catalog.guideRange(), now: now, pointsPerMinute: 1)
        days = GuideDay.days(in: timeline, now: now)
        let day = GuideDay.containing(selectedDayStart ?? now, now: now)
        programmes = catalog.programmes(for: channel, from: day.start, to: day.end)
    }

    private func perform(_ action: ProgrammeAction, channel: CatalogChannel, programme: CatalogProgramme?, now: Date) {
        // Channel up and down walk the channel's category (LIV-5): the page
        // has no chip of its own.
        let neighbours = catalog.channels(categoryID: channel.categoryID)
        let queue = neighbours.contains(where: { $0.key == channel.key }) ? ChannelOrdering.queue(neighbours) : [channel.key.rawValue]
        play(LiveIntents.intent(for: action, channel: channel, programme: programme, now: now, queue: queue))
    }
}

private struct LoadKey: Hashable {
    var itemKey: ItemKey
    var revision: Int
    var profileID: UUID?
    var day: Date?
}

/// A programme on the channel page: mono times, the title (with the
/// catch-up mark when the archive has it), the summary, and on the one on
/// now its progress. Rows that can play are buttons: the one on now plays
/// live, aired ones in the archive play from their start.
private struct ChannelProgrammeRow: View {
    let programme: CatalogProgramme
    let phase: ProgrammePhase
    let isPlayable: Bool
    let now: Date
    let onAction: (ProgrammeAction) -> Void

    private var action: ProgrammeAction? {
        switch phase {
        case .onAir: .watchLive
        case .aired: isPlayable ? .playFromStart : nil
        case .upcoming: nil
        }
    }

    var body: some View {
        Group {
            if let action {
                Button {
                    onAction(action)
                } label: {
                    rowContent
                }
                .buttonStyle(.hearthTile)
                .accessibilityHint(Text(action == .watchLive ? "Plays the channel live" : "Plays the programme from its start"))
            } else {
                rowContent
            }
        }
        .contextMenu {
            if phase == .onAir && isPlayable {
                Button {
                    onAction(.fromTheStart)
                } label: {
                    Label(ProgrammeAction.fromTheStart.title, systemImage: ProgrammeAction.fromTheStart.systemImage)
                }
            }
        }
        .accessibilityActions {
            if phase == .onAir && isPlayable {
                Button(ProgrammeAction.fromTheStart.title) { onAction(.fromTheStart) }
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: HearthFormat.clock(programme.start))
                    .font(.hearthMono(13, weight: phase == .onAir ? .semibold : .regular, relativeTo: .footnote))
                    .foregroundStyle(phase == .onAir ? HearthColor.accent : HearthColor.textSecondary)
                Text(verbatim: HearthFormat.clock(programme.end))
                    .font(.hearthMono(11, relativeTo: .caption2))
                    .foregroundStyle(HearthColor.textTertiary)
            }
            .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if phase == .aired && isPlayable {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HearthColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    Text(programme.title)
                        .font(.hearthText(15, weight: .medium, relativeTo: .body))
                        .foregroundStyle(phase == .aired ? HearthColor.textSecondary : HearthColor.textPrimary)
                        .lineLimit(2)
                    if phase == .onAir {
                        LiveBadge()
                    }
                }
                if let summary = programme.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    Text(summary)
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(2)
                }
                if phase == .onAir {
                    HStack(spacing: 8) {
                        HearthProgressBar(value: programme.progress(at: now), height: 3)
                        Text(verbatim: HearthFormat.remaining(programme.end.timeIntervalSince(now)))
                            .font(.hearthMono(11, relativeTo: .caption2))
                            .foregroundStyle(HearthColor.textSecondary)
                            .layoutPriority(1)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if action != nil {
                Image(systemName: phase == .onAir ? "play.fill" : "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(phase == .onAir ? HearthColor.accent : HearthColor.textSecondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: HearthMetrics.minimumHitTarget)
        .background(phase == .onAir ? HearthColor.surfaceRaised.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ProgrammeText.spokenCell(title: programme.title, start: programme.start, end: programme.end, now: now, isPlayable: phase == .aired && isPlayable)))
    }
}
