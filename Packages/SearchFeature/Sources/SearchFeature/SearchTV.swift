import CatalogKit
import Core
import SwiftUI

/// Search's results on the Apple TV, under tvOS's own search keyboard
/// (`.searchable`): one shelf per kind — channels (select plays live), on TV
/// in the next 24 hours (live, from the archive, or the channel's page),
/// movies and shows (select opens them).
struct SearchTVResults: View {
    let groups: SearchResultGroups
    let onActivate: () -> Void

    @Environment(CatalogService.self) private var catalog
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        let _ = catalog.revision
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: HearthTVMetrics.shelfSpacing) {
                if !groups.channels.isEmpty {
                    channels(at: context.date)
                }
                if !groups.programmes.isEmpty {
                    programmes(at: context.date)
                }
                if !groups.movies.isEmpty {
                    TVShelf(String(localized: "Movies", bundle: .module)) {
                        ForEach(groups.movies) { movie in
                            TVCard(route: .movie(itemKey: movie.key.rawValue), width: HearthTVMetrics.posterWidth, title: movie.name, caption: movie.year.map(String.init)) {
                                TVPosterArtwork(title: movie.name, url: movie.posterURL)
                            }
                        }
                    }
                }
                if !groups.series.isEmpty {
                    TVShelf(String(localized: "Shows", bundle: .module)) {
                        ForEach(groups.series) { series in
                            TVCard(route: .series(itemKey: series.key.rawValue), width: HearthTVMetrics.posterWidth, title: series.name, caption: series.year.map(String.init)) {
                                TVPosterArtwork(title: series.name, url: series.posterURL)
                            }
                        }
                    }
                }
            }
        }
    }

    private func channels(at date: Date) -> some View {
        let queue = groups.channels.map(\.key.rawValue)
        return TVShelf(String(localized: "Channels", bundle: .module)) {
            ForEach(groups.channels) { channel in
                let now = catalog.nowAndNext(for: channel, at: date).now
                TVCard(width: HearthTVMetrics.landscapeWidth) {
                    onActivate()
                    play(PlayIntent(itemKey: channel.key.rawValue, kind: .live, title: channel.name, subtitle: now?.title, artworkURL: channel.logoURL, queue: queue))
                } artwork: {
                    TVChannelArtwork(
                        name: channel.name,
                        number: channel.number,
                        logoURL: channel.logoURL,
                        programmeTitle: now?.title,
                        timing: now.map { ProgrammeTiming(start: $0.start, end: $0.end) },
                        now: date
                    )
                }
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

    private func programmes(at date: Date) -> some View {
        TVShelf(String(localized: "On TV", bundle: .module)) {
            ForEach(groups.programmes) { hit in
                let action = ProgrammeHitAction.resolve(hit.programme, now: date)
                TVCard(width: HearthTVMetrics.landscapeWidth, title: hit.programme.title, caption: SearchTimeText.when(hit.programme, now: date)) {
                    onActivate()
                    switch action {
                    case .watchLive:
                        play(PlayIntent(itemKey: hit.channel.key.rawValue, kind: .live, title: hit.channel.name, subtitle: hit.programme.title, artworkURL: hit.channel.logoURL, queue: [hit.channel.key.rawValue]))
                    case .watchCatchUp:
                        play(PlayIntent(itemKey: hit.channel.key.rawValue, kind: .catchup, title: hit.programme.title, subtitle: hit.channel.name, artworkURL: hit.channel.logoURL, catchupStart: hit.programme.start, catchupEnd: hit.programme.end))
                    case .openChannel:
                        openRoute(.channel(itemKey: hit.channel.key.rawValue))
                    }
                } artwork: {
                    TVChannelArtwork(
                        name: hit.channel.name,
                        number: hit.channel.number,
                        logoURL: hit.channel.logoURL,
                        programmeTitle: action == .watchLive ? hit.programme.title : nil,
                        timing: action == .watchLive ? ProgrammeTiming(start: hit.programme.start, end: hit.programme.end) : nil,
                        now: date
                    )
                }
            }
        }
    }
}

/// A notice on the TV's search page (nothing typed, no results).
struct SearchTVNotice: View {
    let systemName: String
    let title: String
    let message: String

    var body: some View {
        TVNoticeCard(systemName: systemName, title: title, message: message)
            .frame(maxWidth: 1200, alignment: .leading)
    }
}
