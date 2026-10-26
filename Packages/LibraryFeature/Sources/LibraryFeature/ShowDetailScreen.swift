import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// A show (mockup 04; SER-1, SER-2, SER-3): the hero, "Resume S2 E5" (or the
/// next unwatched episode), the My List heart, where the rest of the
/// household is in it, the season picker and each season's episodes with
/// their watched marks and resume points.
struct ShowDetailScreen: View {
    let itemKey: ItemKey

    @Environment(CatalogService.self) private var catalog

    var body: some View {
        let _ = catalog.revision
        if let series = catalog.seriesItem(itemKey) {
            ShowDetailContent(series: series)
        } else {
            UnavailableItemView(itemKey: itemKey, kind: .series)
        }
    }
}

/// How far the episode list has got: shown from the cache at once, refreshed
/// from the provider behind it.
enum EpisodeLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

private struct ShowDetailContent: View {
    let series: CatalogSeries

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout
    @Environment(\.play) private var play

    @State private var episodes: [CatalogEpisode] = []
    @State private var loadState = EpisodeLoadState.idle
    @State private var selectedSeason: Int?
    /// Bumped by "Try again" to re-run the load.
    @State private var attempt = 0

    private struct LoadKey: Hashable {
        var seriesKey: ItemKey
        var attempt: Int
    }

    /// The profile that saves progress; nil for a Guest.
    private var profile: ProfileRecord? {
        session.currentProfile.flatMap { $0.isGuest ? nil : $0 }
    }

    var body: some View {
        let _ = store.revision
        let grouping = SeasonGrouping(episodes)
        let progress = progressByKey()
        let target = ShowPlayTarget.choose(episodes: grouping.orderedEpisodes, progress: progress)
        let seasonCount = grouping.numberedSeasonCount > 0 ? grouping.numberedSeasonCount : nil

        DetailScaffold(title: series.name, metaParts: MetaLine.series(series, seasonCount: seasonCount), artworkURL: series.posterURL) {
            actions(target: target, grouping: grouping)
        } aside: {
            householdCard(progress: progress)
            if let plot = series.plot?.trimmingCharacters(in: .whitespacesAndNewlines), !plot.isEmpty {
                ExpandableText(text: plot, collapsedLines: 3)
            }
        } content: {
            episodesSection(grouping: grouping, progress: progress, target: target)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: series.year.map { "\(series.name) (\($0))" } ?? series.name) {
                    Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
                }
            }
        }
        .task(id: LoadKey(seriesKey: series.key, attempt: attempt)) {
            await loadEpisodes()
        }
    }

    // MARK: Data

    /// The profile's rows for this show, by episode key.
    private func progressByKey() -> [String: ProgressRecord] {
        guard let profile else { return [:] }
        let rows = store.seriesProgress(profileID: profile.id, seriesKey: series.key.rawValue)
        return Dictionary(rows.map { ($0.itemKey, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
    }

    private func loadEpisodes() async {
        let cached = catalog.cachedEpisodes(seriesKey: series.key)
        if !cached.isEmpty {
            episodes = cached
            pickSeasonIfNeeded()
        }
        loadState = .loading
        do {
            let fresh = try await catalog.episodes(for: series)
            episodes = fresh
            loadState = .loaded
            pickSeasonIfNeeded()
        } catch is CancellationError {
            // The screen went away or a retry replaced this load.
        } catch {
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Opens on the season "Resume" plays from, once; after that the picker
    /// stays where the person put it, even when marking an episode watched
    /// moves the target into the next season.
    private func pickSeasonIfNeeded() {
        let grouping = SeasonGrouping(episodes)
        if let selectedSeason, grouping.season(selectedSeason) != nil { return }
        let target = ShowPlayTarget.choose(episodes: grouping.orderedEpisodes, progress: progressByKey())
        selectedSeason = target?.episode.season ?? grouping.seasonNumbers.first
    }

    private func season(in grouping: SeasonGrouping) -> SeasonGrouping.Season? {
        if let selectedSeason, let season = grouping.season(selectedSeason) { return season }
        return grouping.seasons.first
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(target: ShowPlayTarget?, grouping: SeasonGrouping) -> some View {
        HStack(spacing: 10) {
            if let target {
                DetailPlayButton(title: target.title, spokenTitle: target.spokenTitle) {
                    playEpisode(target.episode, start: target.startPosition, grouping: grouping)
                }
            } else {
                DetailPlayButton(
                    title: episodes.isEmpty && loadState != .loaded && !isFailed
                        ? String(localized: "Loading episodes…", bundle: .module) : String(localized: "Play", bundle: .module),
                    spokenTitle: String(localized: "Play", bundle: .module),
                    isEnabled: false
                ) {}
            }
            MyListHeartButton(itemKey: series.key, kind: .series)
        }
    }

    private var isFailed: Bool {
        if case .failed = loadState { return true }
        return false
    }

    private func playEpisode(_ episode: CatalogEpisode, start: TimeInterval?, grouping: SeasonGrouping) {
        play(PlayIntent(
            itemKey: episode.key.rawValue,
            kind: .episode,
            title: series.name,
            subtitle: episode.playerSubtitle,
            artworkURL: episode.posterURL ?? series.posterURL,
            startPosition: start,
            queue: grouping.keys(following: episode.key).map(\.rawValue)
        ))
    }

    // MARK: In this household (SER-3)

    @ViewBuilder
    private func householdCard(progress: [String: ProgressRecord]) -> some View {
        let lines = householdLines(progress: progress)
        // Only worth a card when someone else is watching it too; your own
        // place is already on the main button.
        if lines.contains(where: { !$0.isCurrentProfile }) {
            let profiles = Dictionary(store.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(String(localized: "In this household", bundle: .module), style: .card)
                ForEach(lines) { line in
                    householdRow(line, person: profiles[line.id])
                        .frame(minHeight: 30)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(line.spokenText))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(HearthColor.surface))
            .accessibilityElement(children: .contain)
        }
    }

    /// "Anya · S3 E1 ……… ahead of you" on one line where it fits; in a narrow
    /// column (the opened iPhone Duo's detail pane, large text) the trailing
    /// text drops under the name rather than truncating either.
    private func householdRow(_ line: HouseholdShowLine, person: ProfileRecord?) -> some View {
        let avatar = person.map { AvatarTile(name: $0.name, palette: $0.avatarColor, symbol: $0.avatarSymbol, size: 26) }
        let name = Text(verbatim: "\(line.name) · \(line.episodeCode)")
            .font(.hearthText(14, relativeTo: .callout))
            .foregroundStyle(HearthColor.textPrimary)
        let trailing = Text(line.trailing)
            .font(.hearthMono(12, relativeTo: .caption))
            .foregroundStyle(HearthColor.textSecondary)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                avatar
                name.fixedSize()
                Spacer(minLength: 12)
                trailing.fixedSize()
            }
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    name.fixedSize(horizontal: false, vertical: true)
                    trailing.fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func householdLines(progress: [String: ProgressRecord]) -> [HouseholdShowLine] {
        let mine = progress.values.filter { $0.season != nil }.max { $0.updatedAt < $1.updatedAt }
        var lines: [HouseholdShowLine] = []
        if let profile, let mine, let line = HouseholdShowLine.mine(id: profile.id, progress: mine) {
            lines.append(line)
        }
        // The store never returns a Guest's rows (SER-3).
        let excluded = session.currentProfile?.id ?? UUID()
        for (other, row) in store.householdProgress(seriesKey: series.key.rawValue, excluding: excluded) {
            if let line = HouseholdShowLine.other(id: other.id, name: other.name, progress: row, mine: mine) {
                lines.append(line)
            }
        }
        return lines
    }

    // MARK: Seasons and episodes (SER-1)

    @ViewBuilder
    private func episodesSection(grouping: SeasonGrouping, progress: [String: ProgressRecord], target: ShowPlayTarget?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            seasonPicker(grouping: grouping)

            if episodes.isEmpty {
                emptyEpisodes
            } else {
                if case .failed(let message) = loadState {
                    staleBanner(message)
                }
                if let season = season(in: grouping) {
                    LazyVGrid(columns: episodeColumns, alignment: .leading, spacing: 14) {
                        ForEach(season.episodes) { episode in
                            episodeRow(episode, progress: progress[episode.key.rawValue], grouping: grouping)
                        }
                    }
                }
            }
        }
        .padding(.top, layout == .compact ? 0 : 4)
    }

    /// Up to `maxSegmentedSeasons` seasons as segments (mockup 04); a long
    /// run (soaps, 20-season anime) as a menu, where the open season can't
    /// scroll out of sight. A refresh behind cached episodes shows as a small
    /// spinner beside it.
    /// One column on a phone (an adaptive minimum wider than a small
    /// iPhone would overflow it); two or more where the sidebar layout has
    /// the room, so a Mac window isn't one long thin list.
    private var episodeColumns: [GridItem] {
        switch layout {
        case .compact: [GridItem(.flexible(), alignment: .top)]
        case .sidebar: [GridItem(.adaptive(minimum: 340), spacing: 24, alignment: .top)]
        }
    }

    @ViewBuilder
    private func seasonPicker(grouping: SeasonGrouping) -> some View {
        let selection = Binding(
            get: { season(in: grouping)?.number ?? grouping.seasonNumbers.first ?? 1 },
            set: { selectedSeason = $0 }
        )
        let isRefreshing = loadState == .loading && !episodes.isEmpty
        HStack(spacing: 12) {
            if grouping.seasons.count > Self.maxSegmentedSeasons {
                Menu {
                    Picker(String(localized: "Season", bundle: .module), selection: selection) {
                        ForEach(grouping.seasons) { season in
                            Text(season.title).tag(season.number)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 8) {
                        Text(grouping.season(selection.wrappedValue)?.title ?? "")
                            .font(.hearthText(15, weight: .semibold, relativeTo: .body))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(HearthColor.textPrimary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: HearthMetrics.minimumHitTarget)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HearthColor.surface))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Season", bundle: .module))
                .accessibilityValue(Text(grouping.season(selection.wrappedValue)?.title ?? ""))
                Spacer(minLength: 0)
            } else if grouping.seasons.count > 1 {
                SegmentedPills(String(localized: "Seasons", bundle: .module), options: grouping.seasonNumbers, selection: selection) { number in
                    grouping.season(number)?.title ?? ""
                }
                // Three seasons stretched across a Mac window read as a
                // toolbar, not a picker.
                .frame(maxWidth: layout == .sidebar ? 600 : .infinity, alignment: .leading)
            } else if let only = grouping.seasons.first {
                SectionHeader(only.title)
            }
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(HearthColor.textSecondary)
                    .accessibilityLabel(Text("Checking for new episodes", bundle: .module))
            }
        }
    }

    private static let maxSegmentedSeasons = 6

    @ViewBuilder
    private var emptyEpisodes: some View {
        switch loadState {
        case .idle, .loading:
            LibraryLoadingView(message: String(localized: "Loading episodes…", bundle: .module))
        case .failed(let message):
            EmptyStateView(
                systemName: "exclamationmark.triangle",
                title: String(localized: "Couldn't load the episodes", bundle: .module),
                message: message,
                actionTitle: String(localized: "Try again", bundle: .module),
                action: { attempt += 1 }
            )
        case .loaded:
            EmptyStateView(
                systemName: "tv",
                title: String(localized: "No episodes yet", bundle: .module),
                message: String(localized: "The provider hasn't listed any episodes for this show.", bundle: .module)
            )
        }
    }

    /// Saved episodes are showing, but the provider couldn't be reached for
    /// a fresh list.
    private func staleBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(HearthColor.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing saved episodes", bundle: .module)
                    .font(.hearthText(14, weight: .medium, relativeTo: .callout))
                    .foregroundStyle(HearthColor.textPrimary)
                Text(message)
                    .font(.hearthCaption)
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(String(localized: "Try again", bundle: .module)) { attempt += 1 }
                .buttonStyle(.hearthSecondary(shape: .rounded, size: .small))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HearthColor.surface))
    }

    private func episodeRow(_ episode: CatalogEpisode, progress row: ProgressRecord?, grouping: SeasonGrouping) -> some View {
        let watched = row?.watched ?? false
        let duration = episode.duration.flatMap { $0 > 0 ? $0 : nil } ?? row.flatMap { $0.duration > 0 ? $0.duration : nil }
        let started = row.map { !$0.watched && $0.position >= MoviePlayState.minimumResume && $0.duration > 0 } ?? false
        let fraction: Double? = watched ? 1 : (started ? row?.fraction : nil)
        let resumeAt: TimeInterval? = started ? row?.position : (watched ? 0 : nil)

        return Button {
            playEpisode(episode, start: resumeAt, grouping: grouping)
        } label: {
            EpisodeRow(
                number: episode.number,
                title: episode.title,
                stillURL: episode.posterURL,
                duration: duration,
                remaining: started ? row?.remaining : nil,
                progress: fraction,
                isWatched: watched
            )
        }
        .buttonStyle(.hearthTile)
        .accessibilityHint(Text(started ? "Resumes the episode" : "Plays the episode", bundle: .module))
        .contextMenu {
            if started || watched {
                Button {
                    playEpisode(episode, start: 0, grouping: grouping)
                } label: {
                    Label(String(localized: "Play from the beginning", bundle: .module), systemImage: "arrow.counterclockwise")
                }
            }
            if let profile {
                Button {
                    store.setWatched(!watched, profileID: profile.id, itemKey: episode.key.rawValue)
                } label: {
                    watched
                        ? Label(String(localized: "Mark as unwatched", bundle: .module), systemImage: "arrow.uturn.backward.circle")
                        : Label(String(localized: "Mark as watched", bundle: .module), systemImage: "checkmark.circle")
                }
            }
        }
        .accessibilityActions {
            if let profile {
                Button(watched ? String(localized: "Mark as unwatched", bundle: .module) : String(localized: "Mark as watched", bundle: .module)) {
                    store.setWatched(!watched, profileID: profile.id, itemKey: episode.key.rawValue)
                }
            }
            if started || watched {
                Button(String(localized: "Play from the beginning", bundle: .module)) {
                    playEpisode(episode, start: 0, grouping: grouping)
                }
            }
        }
    }
}
