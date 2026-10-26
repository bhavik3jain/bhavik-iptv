import CatalogKit
import Core
import SwiftUI

// The results: four groups (SRCH-2) drawn with Core's components. On the phone
// they stack — channel and guide rows in grouped cards, posters scrolling
// sideways. In the sidebar layout (iPad, Mac, iPhone Duo opened) channels and
// the guide sit side by side when there is room, and posters become adaptive
// grids.

struct SearchResultsList: View {
    let groups: SearchResultGroups
    /// Write each result's source ("Provider B") when there is more than one
    /// (SRC-7).
    let showsSourceNames: Bool
    @Binding var expanded: Set<SearchSection>
    /// Any result was used: the query goes into recent searches.
    let onActivate: () -> Void

    @Environment(\.hearthLayout) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: HearthMetrics.sectionSpacing + 6) {
            let listSections = groups.sections.filter { $0 == .channels || $0 == .onTV }
            if !listSections.isEmpty {
                if layout == .sidebar {
                    // Two columns where they fit (a Mac window, an iPad);
                    // one on iPhone Duo's narrower inner display.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 340), spacing: 24, alignment: .top)],
                        alignment: .leading,
                        spacing: HearthMetrics.sectionSpacing + 6
                    ) {
                        ForEach(listSections) { section in
                            listSection(section)
                        }
                    }
                } else {
                    ForEach(listSections) { section in
                        listSection(section)
                    }
                }
            }
            if groups.count(of: .movies) > 0 {
                posterSection(.movies)
            }
            if groups.count(of: .shows) > 0 {
                posterSection(.shows)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private func listSection(_ section: SearchSection) -> some View {
        let total = groups.count(of: section)
        let isExpanded = expanded.contains(section)
        let visible = SearchResultLimits.visibleCount(total: total, section: section, layout: layout, expanded: isExpanded)
        ResultSection(section: section, count: total, isCapped: groups.isCapped(section)) {
            GroupedCard(footer: capNote(section, visible: visible)) {
                switch section {
                case .channels:
                    let queue = groups.channels.map(\.key.rawValue)
                    ForEach(groups.channels.prefix(visible)) { channel in
                        ChannelResultButton(channel: channel, queue: queue, showsSourceName: showsSourceNames, onActivate: onActivate)
                    }
                case .onTV:
                    ForEach(groups.programmes.prefix(visible)) { hit in
                        ProgrammeResultButton(hit: hit, onActivate: onActivate)
                    }
                case .movies, .shows:
                    EmptyView()
                }
                if total > SearchResultLimits.collapsedCount(for: section, layout: layout), total > visible || isExpanded {
                    ShowAllRow(section: section, total: total, isExpanded: isExpanded) {
                        if isExpanded { expanded.remove(section) } else { expanded.insert(section) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func posterSection(_ section: SearchSection) -> some View {
        let total = groups.count(of: section)
        let isExpanded = expanded.contains(section)
        let visible = SearchResultLimits.visibleCount(total: total, section: section, layout: layout, expanded: isExpanded)
        ResultSection(section: section, count: total, isCapped: groups.isCapped(section)) {
            if layout == .sidebar {
                VStack(alignment: .leading, spacing: HearthMetrics.itemSpacing) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 16, alignment: .top)],
                        alignment: .leading,
                        spacing: 20
                    ) {
                        posters(section, limit: visible)
                    }
                    if total > SearchResultLimits.collapsedCount(for: section, layout: layout), total > visible || isExpanded {
                        Button {
                            if isExpanded { expanded.remove(section) } else { expanded.insert(section) }
                        } label: {
                            Text(ShowAllRow.title(section: section, total: total, isExpanded: isExpanded))
                        }
                        .buttonStyle(.hearthSecondary(shape: .rounded, size: .small))
                    }
                    if let note = capNote(section, visible: visible) {
                        CapNote(text: note)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: HearthMetrics.itemSpacing) {
                        posters(section, limit: visible)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, HearthMetrics.screenPadding)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                // Posters run to the screen's edges; the section's padding
                // is the scroll content's inset instead.
                .padding(.horizontal, -HearthMetrics.screenPadding)
                if let note = capNote(section, visible: visible) {
                    CapNote(text: note)
                }
            }
        }
    }

    /// "Showing the first 50…" under a group the catalog cut short, once all
    /// of what it returned is on screen.
    private func capNote(_ section: SearchSection, visible: Int) -> String? {
        guard groups.isCapped(section), visible >= groups.count(of: section) else { return nil }
        return String(localized: "Showing the first \(SearchResultLimits.perGroup). Type more of the name to narrow it down.", bundle: .module, comment: "Under a search group that hit its limit")
    }

    @ViewBuilder private func posters(_ section: SearchSection, limit: Int) -> some View {
        switch section {
        case .movies:
            ForEach(groups.movies.prefix(limit)) { movie in
                NavigationLink(value: HearthRoute.movie(itemKey: movie.key.rawValue)) {
                    PosterResultTile(
                        title: movie.name,
                        url: movie.posterURL,
                        detail: PosterDetail.text(year: movie.year, sourceName: showsSourceNames ? movie.sourceName : nil)
                    )
                }
                .buttonStyle(.hearthTile)
                .simultaneousGesture(TapGesture().onEnded(onActivate))
            }
        case .shows:
            ForEach(groups.series.prefix(limit)) { show in
                NavigationLink(value: HearthRoute.series(itemKey: show.key.rawValue)) {
                    PosterResultTile(
                        title: show.name,
                        url: show.posterURL,
                        detail: PosterDetail.text(year: show.year, sourceName: showsSourceNames ? show.sourceName : nil)
                    )
                }
                .buttonStyle(.hearthTile)
                .simultaneousGesture(TapGesture().onEnded(onActivate))
            }
        case .channels, .onTV:
            EmptyView()
        }
    }
}

/// The note under a poster group the catalog cut short, styled like a
/// grouped card's footer.
private struct CapNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.hearthFootnote)
            .foregroundStyle(HearthColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// A group's title ("Channels") with its count, and its content.
private struct ResultSection<Content: View>: View {
    let section: SearchSection
    let count: Int
    /// The catalog stopped at its limit: the count reads "50+".
    let isCapped: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: HearthMetrics.itemSpacing) {
            SectionHeader(section.title) {
                Text(verbatim: isCapped ? "\(count.formatted())+" : count.formatted())
                    .font(.hearthMono(13, relativeTo: .footnote))
                    .foregroundStyle(HearthColor.textTertiary)
                    .accessibilityLabel(Text(section.spokenCount(count)))
            }
            content
        }
    }
}

extension SearchSection {
    var title: String {
        switch self {
        case .channels: String(localized: "Channels", bundle: .module)
        case .onTV: String(localized: "On TV", bundle: .module, comment: "Search group: programmes in the next 24 hours")
        case .movies: String(localized: "Movies", bundle: .module)
        case .shows: String(localized: "Shows", bundle: .module)
        }
    }

    func spokenCount(_ count: Int) -> String {
        switch self {
        case .channels: String(localized: "\(count) channels", bundle: .module)
        case .onTV: String(localized: "\(count) programmes", bundle: .module)
        case .movies: String(localized: "\(count) movies", bundle: .module)
        case .shows: String(localized: "\(count) shows", bundle: .module)
        }
    }
}

/// "Show all 23" / "Show fewer" at the foot of a group.
private struct ShowAllRow: View {
    let section: SearchSection
    let total: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        CardActionRow(Self.title(section: section, total: total, isExpanded: isExpanded),
                      systemImage: isExpanded ? "chevron.up" : "chevron.down",
                      action: action)
    }

    static func title(section: SearchSection, total: Int, isExpanded: Bool) -> String {
        if isExpanded { return String(localized: "Show fewer", bundle: .module) }
        return String(localized: "Show all \(total)", bundle: .module, comment: "Expands a search group: Show all 23")
    }
}

// MARK: - Channels

/// A channel hit: logo, number, name and what's on now. A tap plays it live;
/// channel up and down then walk the channels this search found.
private struct ChannelResultButton: View {
    let channel: CatalogChannel
    let queue: [String]
    let showsSourceName: Bool
    let onActivate: () -> Void

    @Environment(CatalogService.self) private var catalog
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        // Re-read when the short guide lands (revision) and as programmes
        // change on the minute.
        let _ = catalog.revision
        TimelineView(.everyMinute) { context in
            let now = catalog.nowAndNext(for: channel, at: context.date).now
            Button {
                onActivate()
                play(PlayIntent(
                    itemKey: channel.key.rawValue,
                    kind: .live,
                    title: channel.name,
                    subtitle: now?.title,
                    artworkURL: channel.logoURL,
                    queue: queue
                ))
            } label: {
                ChannelResultRow(channel: channel, programme: now, showsSourceName: showsSourceName, date: context.date)
            }
            .buttonStyle(.hearthTile)
            .accessibilityHint(Text("Plays the channel live", bundle: .module))
            .contextMenu {
                Button {
                    onActivate()
                    openRoute(.channel(itemKey: channel.key.rawValue))
                } label: {
                    Label(String(localized: "Open channel guide", bundle: .module), systemImage: "list.bullet.rectangle")
                }
            }
        }
    }
}

private struct ChannelResultRow: View {
    let channel: CatalogChannel
    let programme: CatalogProgramme?
    let showsSourceName: Bool
    let date: Date

    var body: some View {
        let timing = programme.map { ProgrammeTiming(start: $0.start, end: $0.end) }
        HStack(spacing: 12) {
            ChannelLogo(name: channel.name, url: channel.logoURL, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let number = channel.number {
                        Text(verbatim: String(number))
                            .font(.hearthMono(12, relativeTo: .caption))
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                    Text(channel.name)
                        .font(.hearthText(15, weight: .medium, relativeTo: .body))
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.hearthFootnote)
                    .foregroundStyle(programme == nil ? HearthColor.textTertiary : HearthColor.textSecondary)
                    .lineLimit(1)
                if let timing {
                    HearthProgressBar(value: timing.progress(at: date), height: 3)
                        .frame(maxWidth: 180)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HearthColor.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(HearthColor.surfaceRaised))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel(timing: timing)))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let programme {
            parts.append(programme.title)
        } else {
            parts.append(String(localized: "No guide", bundle: .module, comment: "A channel with no programme information"))
        }
        if showsSourceName { parts.append(channel.sourceName) }
        return parts.joined(separator: " · ")
    }

    private func spokenLabel(timing: ProgrammeTiming?) -> String {
        var sentence = ChannelText.spokenNowPlaying(number: channel.number, name: channel.name, programme: programme?.title, timing: timing, isLive: true, at: date)
        if showsSourceName { sentence += ". " + String(localized: "From \(channel.sourceName)", bundle: .module) }
        return sentence
    }
}

// MARK: - On TV

/// A guide hit in the next 24 hours. What a tap does depends on the time
/// (`ProgrammeHitAction`): on now plays live, aired-and-archived plays the
/// catch-up, anything later opens the channel's page.
private struct ProgrammeResultButton: View {
    let hit: SearchResults.ProgrammeHit
    let onActivate: () -> Void

    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        TimelineView(.everyMinute) { context in
            let action = ProgrammeHitAction.resolve(hit.programme, now: context.date)
            Group {
                switch action {
                case .watchLive, .watchCatchUp:
                    Button {
                        onActivate()
                        play(intent(for: action))
                    } label: {
                        ProgrammeResultRow(hit: hit, action: action, date: context.date)
                    }
                case .openChannel:
                    NavigationLink(value: HearthRoute.channel(itemKey: hit.channel.key.rawValue)) {
                        ProgrammeResultRow(hit: hit, action: action, date: context.date)
                    }
                    .simultaneousGesture(TapGesture().onEnded(onActivate))
                }
            }
            .buttonStyle(.hearthTile)
            .accessibilityHint(Text(hint(for: action)))
            .contextMenu { menu(action: action, now: context.date) }
        }
    }

    @ViewBuilder private func menu(action: ProgrammeHitAction, now: Date) -> some View {
        // "From the start" for a programme on now whose channel keeps an
        // archive (LIV-4).
        if action == .watchLive, hit.programme.hasArchive {
            Button {
                onActivate()
                play(catchUpIntent())
            } label: {
                Label(String(localized: "Watch from the start", bundle: .module), systemImage: "backward.end")
            }
        }
        if action != .watchLive {
            Button {
                onActivate()
                play(liveIntent())
            } label: {
                Label(String(localized: "Watch \(hit.channel.name) live", bundle: .module), systemImage: "play")
            }
        }
        Button {
            onActivate()
            openRoute(.channel(itemKey: hit.channel.key.rawValue))
        } label: {
            Label(String(localized: "Open channel guide", bundle: .module), systemImage: "list.bullet.rectangle")
        }
    }

    private func intent(for action: ProgrammeHitAction) -> PlayIntent {
        action == .watchCatchUp ? catchUpIntent() : liveIntent()
    }

    private func liveIntent() -> PlayIntent {
        PlayIntent(
            itemKey: hit.channel.key.rawValue,
            kind: .live,
            title: hit.channel.name,
            subtitle: hit.programme.title,
            artworkURL: hit.channel.logoURL,
            queue: [hit.channel.key.rawValue]
        )
    }

    private func catchUpIntent() -> PlayIntent {
        PlayIntent(
            itemKey: hit.channel.key.rawValue,
            kind: .catchup,
            title: hit.programme.title,
            subtitle: hit.channel.name,
            artworkURL: hit.channel.logoURL,
            catchupStart: hit.programme.start,
            catchupEnd: hit.programme.end
        )
    }

    private func hint(for action: ProgrammeHitAction) -> String {
        switch action {
        case .watchLive: String(localized: "Plays the channel live", bundle: .module)
        case .watchCatchUp: String(localized: "Plays the programme from the archive", bundle: .module)
        case .openChannel: String(localized: "Opens the channel's guide", bundle: .module)
        }
    }
}

private struct ProgrammeResultRow: View {
    let hit: SearchResults.ProgrammeHit
    let action: ProgrammeHitAction
    let date: Date

    var body: some View {
        let programme = hit.programme
        HStack(spacing: 12) {
            ChannelLogo(name: hit.channel.name, url: hit.channel.logoURL, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                if action == .watchLive {
                    LiveBadge()
                }
                Text(programme.title)
                    .font(.hearthText(15, weight: .medium, relativeTo: .body))
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(SearchTimeText.when(programme, now: date))
                        .font(.hearthMono(12, relativeTo: .caption))
                        .foregroundStyle(action == .watchLive ? HearthColor.accent : HearthColor.textSecondary)
                    Text(verbatim: "·")
                        .foregroundStyle(HearthColor.textTertiary)
                    Text(ChannelText.numberedName(number: hit.channel.number, name: hit.channel.name))
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(1)
                }
                if action == .watchLive {
                    HearthProgressBar(value: programme.progress(at: date), height: 3)
                        .frame(maxWidth: 180)
                        .padding(.top, 3)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingGlyph
        }
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SearchTimeText.spoken(hit, now: date)))
    }

    @ViewBuilder private var trailingGlyph: some View {
        switch action {
        case .watchLive, .watchCatchUp:
            Image(systemName: action == .watchLive ? "play.fill" : "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HearthColor.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(HearthColor.surfaceRaised))
                .accessibilityHidden(true)
        case .openChannel:
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HearthColor.glyphMuted)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Posters

/// The line under a poster: "2019 · Provider B".
enum PosterDetail {
    static func text(year: Int?, sourceName: String?) -> String? {
        let parts = [year.map { String($0) }, sourceName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A movie or show hit: Core's poster with its title and year under it, since
/// many providers send no artwork and a coloured placeholder alone doesn't
/// say which film it is.
private struct PosterResultTile: View {
    let title: String
    let url: URL?
    let detail: String?

    @Environment(\.hearthLayout) private var layout
    @ScaledMetric(relativeTo: .body) private var compactWidth: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterTile(title: title, url: url)
            Text(title)
                .font(.hearthText(13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(HearthColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.hearthCaption)
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: layout == .compact ? compactWidth : nil, alignment: .leading)
        .frame(maxWidth: layout == .compact ? nil : .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([title, detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isLink)
    }
}
