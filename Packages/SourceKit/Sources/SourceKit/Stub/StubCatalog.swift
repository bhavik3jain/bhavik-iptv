import Foundation

/// The stub provider's catalog: channels, a guide, movies and shows named
/// like the mockups' placeholders, all deterministic (the same input always
/// gives the same catalog), streaming Apple's public HLS samples. Nothing
/// here needs a login or reaches a real provider.
enum StubCatalog {
    // MARK: Streams

    /// Apple's public sample streams. HLS plays in AVPlayer; the raw MPEG-TS
    /// segment exercises the VLC engine.
    static let hlsSamples = [
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8",
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8",
    ]
    static let mpegTSSample = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear1/fileSequence0.ts"

    static func hlsSample(_ seed: Int) -> String {
        hlsSamples[abs(seed) % hlsSamples.count]
    }

    // MARK: Categories

    static let liveCategories: [RemoteCategory] = [
        ("news", "News"), ("sports", "Sports"), ("drama", "Drama"), ("docs", "Docs"),
        ("movies", "Movies"), ("kids", "Kids"), ("music", "Music"),
        // Exercises adult-category filtering (PAR-1); its channel is a test card.
        ("adult", "Adult"),
    ].enumerated().map { RemoteCategory(id: $1.0, name: $1.1, kind: .live, sortOrder: $0) }

    static let movieCategories: [RemoteCategory] = [
        ("m-drama", "Drama"), ("m-thriller", "Thriller"), ("m-comedy", "Comedy"),
        ("m-family", "Family"), ("m-docs", "Documentary"), ("m-classics", "Classics"),
    ].enumerated().map { RemoteCategory(id: $1.0, name: $1.1, kind: .vod, sortOrder: $0) }

    static let seriesCategories: [RemoteCategory] = [
        ("s-drama", "Drama"), ("s-kids", "Kids"), ("s-reality", "Reality"), ("s-docs", "Documentary"),
    ].enumerated().map { RemoteCategory(id: $1.0, name: $1.1, kind: .series, sortOrder: $0) }

    // MARK: Channels

    private struct ChannelSeed {
        let number: Int
        let name: String
        let category: String
        let archive: Bool
    }

    private static let channelSeeds: [ChannelSeed] = [
        .init(number: 101, name: "Cityline News", category: "news", archive: true),
        .init(number: 102, name: "Fieldhouse Sports", category: "sports", archive: true),
        .init(number: 103, name: "Lantern Drama", category: "drama", archive: false),
        .init(number: 104, name: "Northwind Docs", category: "docs", archive: true),
        .init(number: 105, name: "Kestrel Cinema", category: "movies", archive: false),
        .init(number: 106, name: "Little Owl Kids", category: "kids", archive: true),
        .init(number: 107, name: "Pulse Music", category: "music", archive: true),
        .init(number: 108, name: "Harbourside News 24", category: "news", archive: false),
        .init(number: 109, name: "Meridian Business", category: "news", archive: true),
        .init(number: 110, name: "Courtside", category: "sports", archive: false),
        .init(number: 111, name: "Trackside Motors", category: "sports", archive: true),
        .init(number: 112, name: "Fieldhouse Sports 2", category: "sports", archive: false),
        .init(number: 113, name: "Velvet Stage", category: "drama", archive: true),
        .init(number: 114, name: "Blue Hour", category: "drama", archive: false),
        .init(number: 115, name: "Wildframe", category: "docs", archive: true),
        .init(number: 116, name: "Atlas Travel", category: "docs", archive: false),
        .init(number: 117, name: "Kestrel Classics", category: "movies", archive: true),
        .init(number: 118, name: "Midnight Reel", category: "movies", archive: false),
        .init(number: 119, name: "Paper Kite", category: "kids", archive: false),
        .init(number: 120, name: "Tiny Planet", category: "kids", archive: true),
        .init(number: 121, name: "Echo FM TV", category: "music", archive: false),
        .init(number: 122, name: "Vinyl Lounge", category: "music", archive: false),
        .init(number: 123, name: "MPEG-TS Test", category: "docs", archive: false),
        .init(number: 124, name: "Cityline Weather", category: "news", archive: false),
        .init(number: 199, name: "Adult Test Card", category: "adult", archive: false),
    ]

    static let channels: [RemoteChannel] = channelSeeds.enumerated().map { index, seed in
        let isTS = seed.name == "MPEG-TS Test"
        return RemoteChannel(
            id: "ch\(seed.number)",
            number: seed.number,
            name: seed.name,
            logoURL: nil,
            categoryID: seed.category,
            guideChannelID: "ch\(seed.number).stub",
            hasArchive: seed.archive,
            archiveDays: seed.archive ? 7 : 0,
            command: isTS ? mpegTSSample : hlsSample(index),
            formatHint: isTS ? .mpegts : .hls
        )
    }

    // MARK: Guide

    private static let titles: [String: [String]] = [
        "news": ["Evening Bulletin", "Market Close", "World Desk", "Morning Briefing", "Midday Update", "Late Edition", "The Week in Review", "Weather Watch"],
        "sports": ["Premier Cricket · Final", "Premier Cricket · Final, 2nd innings", "Post-match: The Verdict", "Matchday Live", "The Sports Desk", "Tennis Tonight", "Motorsport Weekly", "Goal Rush"],
        "drama": ["The Long Harbor · S3 E#", "Night Shift Dispatch · S1 E#", "Salt & Signal · S2 E#", "Monsoon Letters", "Glass Orchard", "Copper Sky · S1 E#"],
        "docs": ["Salt Road", "Deep Water Cities", "Night Skies", "Bridges of the North", "Wild Coasts", "Ancient Engines", "Field Notes · E#"],
        "movies": ["The Quiet Engine (1962)", "Glass Orchard (2019)", "Last Train to Halden (1974)", "A Map of Rain (2021)", "Copper Sky (2008)", "The Ninth Lantern (1995)"],
        "kids": ["Paper Boats", "Moon Garden", "Bedtime Stories", "Tiny Builders", "Owl & Friends", "Kite Club"],
        "music": ["Throwback Hour", "Late Charts", "Unplugged", "Morning Mix", "Live at the Lantern", "Vinyl Sessions"],
        "adult": ["Test Card"],
    ]

    private static let summaries: [String: [String]] = [
        "news": ["The day's headlines, with reports from around the region.", "Markets, money and the stories behind the numbers.", "Correspondents on the stories shaping the world tonight."],
        "sports": ["Live coverage with analysis from the studio.", "Highlights, interviews and the talking points.", "Every result and every replay that matters."],
        "drama": ["Old loyalties are tested when a stranger arrives in port.", "A long night on the dispatch desk turns personal.", "A message from the lighthouse changes everything."],
        "docs": ["A journey along a forgotten trade route.", "How cities are learning to live with the sea.", "The science and wonder of the night sky."],
        "movies": ["A quiet engineer finds himself at the centre of a storm.", "Three sisters return to the family orchard for one last summer.", "A classic from the archive, restored."],
        "kids": ["Stories, songs and a little bit of mischief.", "Building, painting and playing together.", "Gentle tales to wind down the day."],
        "music": ["The songs that defined a decade.", "This week's chart, counted down.", "Stripped-back sets from the studio."],
        "adult": ["An innocuous test card used to check category filtering."],
    ]

    /// Every programme of `channel` between `from` and `to`. Each day starts
    /// fresh at midnight UTC and is a function of the channel and the day
    /// alone, so any window of the guide agrees with any other.
    static func programmes(for channel: RemoteChannel, from: Date, to: Date, now: Date) -> [RemoteProgramme] {
        guard let guideID = channel.guideChannelID else { return [] }
        let category = channel.categoryID ?? "news"
        let pool = titles[category] ?? ["Programme"]
        let summaryPool = summaries[category] ?? []
        let channelSeed = stableSeed(channel.id)
        var result: [RemoteProgramme] = []
        var day = floor(from.timeIntervalSince1970 / 86_400) * 86_400
        while day < to.timeIntervalSince1970 {
            let dayIndex = Int(day / 86_400)
            var start = day
            var slot = 0
            while start < day + 86_400 {
                let seed = mix(channelSeed, dayIndex, slot)
                // 30, 60 or 90 minutes; films run long.
                let minutes = category == "movies" ? [90, 90, 120][seed % 3] : [30, 60, 60, 90][seed % 4]
                let end = min(start + Double(minutes * 60), day + 86_400)
                if end > from.timeIntervalSince1970, start < to.timeIntervalSince1970 {
                    var title = pool[(seed / 7) % pool.count]
                    if title.contains("#") { title = title.replacingOccurrences(of: "#", with: String(1 + (dayIndex + slot) % 10)) }
                    let startDate = Date(timeIntervalSince1970: start)
                    let endDate = Date(timeIntervalSince1970: end)
                    result.append(RemoteProgramme(
                        guideChannelID: guideID,
                        start: startDate,
                        end: endDate,
                        title: title,
                        summary: summaryPool.isEmpty ? nil : summaryPool[(seed / 3) % summaryPool.count],
                        category: liveCategories.first { $0.id == category }?.name,
                        hasArchive: channel.hasArchive && endDate < now && endDate > now.addingTimeInterval(-7 * 86_400)
                    ))
                }
                start = end
                slot += 1
            }
            day += 86_400
        }
        return result
    }

    // MARK: Movies

    private struct MovieSeed {
        let name: String
        let category: String
        let year: Int
    }

    private static let movieSeeds: [MovieSeed] = [
        .init(name: "The Quiet Engine", category: "m-classics", year: 1962),
        .init(name: "Glass Orchard", category: "m-drama", year: 2019),
        .init(name: "Deep Water Cities", category: "m-docs", year: 2023),
        .init(name: "Paper Boats", category: "m-family", year: 2021),
        .init(name: "Moon Garden", category: "m-family", year: 2022),
        .init(name: "Monsoon Letters", category: "m-drama", year: 2020),
        .init(name: "Northern Lights Hotel", category: "m-comedy", year: 2017),
        .init(name: "A Map of Rain", category: "m-drama", year: 2021),
        .init(name: "The Cartographer's Daughter", category: "m-drama", year: 2015),
        .init(name: "Last Train to Halden", category: "m-classics", year: 1974),
        .init(name: "Copper Sky", category: "m-thriller", year: 2008),
        .init(name: "The Ninth Lantern", category: "m-thriller", year: 1995),
        .init(name: "Small Hours", category: "m-thriller", year: 2024),
        .init(name: "Ferryman's Wake", category: "m-thriller", year: 2012),
        .init(name: "Salt and Cedar", category: "m-drama", year: 2018),
        .init(name: "Winter Orchard", category: "m-drama", year: 2010),
        .init(name: "The Weight of Feathers", category: "m-drama", year: 2022),
        .init(name: "Brass Harbor", category: "m-classics", year: 1958),
        .init(name: "Signal Hill", category: "m-thriller", year: 2016),
        .init(name: "The Long Way Round", category: "m-comedy", year: 2013),
        .init(name: "Neon Tide", category: "m-thriller", year: 2025),
        .init(name: "Kite Season", category: "m-family", year: 2019),
        .init(name: "Orchard Road", category: "m-comedy", year: 2009),
        .init(name: "The Glass Archive", category: "m-docs", year: 2020),
        .init(name: "Hollow Bay", category: "m-thriller", year: 2014),
        .init(name: "Tin Soldiers", category: "m-classics", year: 1969),
        .init(name: "Midnight Bakery", category: "m-comedy", year: 2023),
        .init(name: "The Understudy", category: "m-drama", year: 2011),
        .init(name: "Riverstone", category: "m-drama", year: 2006),
        .init(name: "Field of Lanterns", category: "m-family", year: 2024),
        .init(name: "Lighthouse Rules", category: "m-comedy", year: 2018),
        .init(name: "Echo Valley", category: "m-thriller", year: 2002),
        .init(name: "A House of Paper", category: "m-drama", year: 2025),
        .init(name: "Storm Choir", category: "m-docs", year: 2021),
        .init(name: "Quiet Neighbours", category: "m-comedy", year: 2016),
        .init(name: "The Last Reel", category: "m-classics", year: 1981),
        .init(name: "Clockwork Garden", category: "m-family", year: 2015),
        .init(name: "Little Owl's Big Night", category: "m-family", year: 2023),
        .init(name: "Harbor Lights", category: "m-classics", year: 1949),
        .init(name: "The Sound of Snow", category: "m-docs", year: 2019),
    ]

    private static let plots = [
        "When a storm cuts the town off for a week, old secrets surface one by one.",
        "A retired engineer is drawn back for one last job that isn't what it seems.",
        "Two strangers share a long journey north and more than they planned to.",
        "A family gathers for a summer that will change all of them.",
        "An unlikely friendship grows between a lighthouse keeper and a runaway.",
        "A small bakery becomes the centre of a neighbourhood's quiet revolution.",
        "A detective follows a trail of letters across three decades.",
        "The story of the people who keep a coastal city above water.",
        "A young inventor builds a machine that answers the wrong questions.",
        "Lost in the city at night, a little owl finds her way home.",
    ]

    static let movieGenres = ["m-drama": "Drama", "m-thriller": "Thriller", "m-comedy": "Comedy", "m-family": "Family", "m-docs": "Documentary", "m-classics": "Classic"]

    /// Movies newest first; `addedAt` steps back four days per title from
    /// the start of `now`'s day, so the stub always has recent additions.
    static func movies(now: Date) -> [RemoteMovie] {
        let today = floor(now.timeIntervalSince1970 / 86_400) * 86_400
        return movieSeeds.enumerated().map { index, seed in
            let hash = stableSeed(seed.name)
            return RemoteMovie(
                id: "mv\(1000 + index)",
                name: seed.name,
                categoryID: seed.category,
                posterURL: nil,
                year: seed.year,
                plot: plots[hash % plots.count],
                rating: Double(55 + hash % 40) / 10,
                durationSeconds: (84 + hash % 60) * 60,
                containerExtension: "m3u8",
                addedAt: Date(timeIntervalSince1970: today - Double(index) * 4 * 86_400),
                genre: movieGenres[seed.category],
                cast: nil,
                director: nil,
                command: hlsSample(hash)
            )
        }
    }

    // MARK: Series

    private struct SeriesSeed {
        let name: String
        let category: String
        let year: Int
        let seasons: [Int]
        let episodeMinutes: Int
        let plot: String
    }

    private static let seriesSeeds: [SeriesSeed] = [
        .init(name: "Salt & Signal", category: "s-drama", year: 2024, seasons: [6, 8, 8], episodeMinutes: 51,
              plot: "On a storm-battered island, the keepers of an old signal station uncover what the sea has been hiding."),
        .init(name: "The Long Harbor", category: "s-drama", year: 2021, seasons: [8, 8, 10], episodeMinutes: 48,
              plot: "A harbour town's families, feuds and fortunes across three generations."),
        .init(name: "Kitchen Wars", category: "s-reality", year: 2022, seasons: [10, 10], episodeMinutes: 42,
              plot: "Home cooks face off in a converted warehouse kitchen; one leaves each week."),
        .init(name: "Night Shift Dispatch", category: "s-drama", year: 2023, seasons: [8, 8], episodeMinutes: 47,
              plot: "The night crew of a city's emergency dispatch centre, one call at a time."),
        .init(name: "Paper Boats", category: "s-kids", year: 2020, seasons: [12], episodeMinutes: 11,
              plot: "Three friends sail paper boats to imaginary islands."),
        .init(name: "Moon Garden", category: "s-kids", year: 2021, seasons: [10, 10], episodeMinutes: 12,
              plot: "A garden that only blooms at night, and the creatures who tend it."),
        .init(name: "Monsoon Letters", category: "s-drama", year: 2019, seasons: [6], episodeMinutes: 55,
              plot: "Letters found in an old house link two families across one rainy season."),
        .init(name: "Glass Orchard", category: "s-drama", year: 2022, seasons: [6], episodeMinutes: 50,
              plot: "Three sisters inherit an orchard and the debts that come with it."),
        .init(name: "Deep Water Cities", category: "s-docs", year: 2023, seasons: [5], episodeMinutes: 45,
              plot: "How the world's coastal cities are learning to live with rising water."),
        .init(name: "Field Notes", category: "s-docs", year: 2025, seasons: [8], episodeMinutes: 30,
              plot: "A naturalist's notebook, brought to life one habitat at a time."),
    ]

    private static let episodeTitlePool = [
        "Arrivals", "The Breakwater", "Static", "Open Water", "Crosswinds", "Old Debts", "First Light", "The Long Night",
        "Undertow", "Harbour Lights", "Second Chances", "The Visitor", "High Tide", "Paper Trail", "Homecoming", "Last Orders",
    ]

    /// The episode names the mockups show for Salt & Signal's second season.
    private static let saltAndSignalSeasonTwo = ["Low Tide", "The Breakwater", "Static", "Fog Bell", "The Lighthouse Keeper", "Low Water", "Signal Fire", "Homeport"]

    static func series(now: Date) -> [RemoteSeries] {
        let today = floor(now.timeIntervalSince1970 / 86_400) * 86_400
        return seriesSeeds.enumerated().map { index, seed in
            RemoteSeries(
                id: "sr\(200 + index)",
                name: seed.name,
                categoryID: seed.category,
                posterURL: nil,
                plot: seed.plot,
                year: seed.year,
                rating: Double(70 + stableSeed(seed.name) % 25) / 10,
                addedAt: Date(timeIntervalSince1970: today - Double(index) * 9 * 86_400),
                genre: seriesCategories.first { $0.id == seed.category }?.name,
                cast: nil
            )
        }
    }

    static func detail(for series: RemoteSeries) -> SeriesDetail {
        let byID = seriesSeeds.indices.first { "sr\(200 + $0)" == series.id }
        guard let index = byID ?? seriesSeeds.firstIndex(where: { $0.name == series.name }) else {
            return SeriesDetail(series: series, seasons: [], episodes: [])
        }
        return detail(seedIndex: index, series: series)
    }

    private static func detail(seedIndex: Int, series: RemoteSeries) -> SeriesDetail {
        let seed = seriesSeeds[seedIndex]
        var seasons: [RemoteSeason] = []
        var episodes: [RemoteEpisode] = []
        for (seasonIndex, count) in seed.seasons.enumerated() {
            let season = seasonIndex + 1
            seasons.append(RemoteSeason(number: season, name: "Season \(season)", remoteID: "\(series.id)-s\(season)"))
            for number in 1...count {
                let title: String
                if seed.name == "Salt & Signal", season == 2, number <= saltAndSignalSeasonTwo.count {
                    title = saltAndSignalSeasonTwo[number - 1]
                } else {
                    title = episodeTitlePool[mix(stableSeed(seed.name), season, number) % episodeTitlePool.count]
                }
                episodes.append(RemoteEpisode(
                    id: "\(series.id)-s\(season)e\(number)",
                    seriesID: series.id,
                    season: season,
                    number: number,
                    title: title,
                    plot: "\(seed.name), season \(season), episode \(number).",
                    durationSeconds: seed.episodeMinutes * 60,
                    containerExtension: "m3u8",
                    posterURL: nil,
                    command: hlsSample(season + number)
                ))
            }
        }
        return SeriesDetail(series: series, seasons: seasons, episodes: episodes)
    }

    // MARK: Determinism

    /// FNV-1a of the text, folded to a non-negative Int.
    static func stableSeed(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash >> 33)
    }

    static func mix(_ values: Int...) -> Int {
        var hash: UInt64 = 0x9E37_79B9_7F4A_7C15
        for value in values {
            hash ^= UInt64(bitPattern: Int64(value))
            hash = (hash ^ (hash >> 30)) &* 0xBF58_476D_1CE4_E5B9
            hash = (hash ^ (hash >> 27)) &* 0x94D0_49BB_1331_11EB
            hash ^= hash >> 31
        }
        return Int(hash >> 33)
    }
}
