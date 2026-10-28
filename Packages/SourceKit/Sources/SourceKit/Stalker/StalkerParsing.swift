import Foundation

/// A portal answer: `{"js": …, "text": …}`. Nil when the body isn't one —
/// an expired token gets the plain text `Authorization failed.`, a wrong path
/// an HTML page.
struct StalkerEnvelope: Sendable {
    var js: JSONValue
    var text: String?

    init?(data: Data) {
        var body = data
        // JsHttpRequest's "secure" framing, which a few portals keep:
        // `/*-secure- {...} */`.
        let secure = Data("/*-secure-".utf8)
        if body.starts(with: secure) {
            body = body.dropFirst(secure.count)
            if let close = body.range(of: Data("*/".utf8), options: .backwards) { body = body[..<close.lowerBound] }
        }
        guard let value = JSONValue(data: Data(body)), value.object != nil, let js = value["js"] else { return nil }
        self.js = js
        text = value["text"]?.string
    }

    /// What the portal said in words, if anything worth showing (SRC-4).
    /// Ministra fills `text` with debug timings ("generated in: 0.01s; query
    /// counter: 8…"), which is not a message.
    var message: String? {
        if let message = js.string("msg", "block_msg", "error", "message", "status_msg", "err_msg") { return message }
        guard let text, !text.lowercased().hasPrefix("generated in") else { return nil }
        return text
    }

    /// True when the portal's words say the session is gone.
    var saysUnauthorised: Bool {
        guard let text = text?.lowercased() else { return false }
        return text.contains("authorization failed") || text.contains("unauthorized") || text.contains("not authorized")
    }
}

/// One page of `get_ordered_list`.
struct StalkerListPage: Sendable {
    var items: [JSONValue]
    /// `js.total_items`; nil for a bare array, which is the whole list.
    var totalItems: Int?
    /// `js.max_page_items` (14 on Ministra).
    var pageSize: Int?

    /// Whether another page follows `page` (0-based).
    func hasMore(after page: Int) -> Bool {
        guard let totalItems, !items.isEmpty else { return false }
        let size = max(pageSize ?? items.count, 1)
        return page * size + items.count < totalItems
    }
}

/// Pure readers for Stalker answers, shared by the client and the tests.
/// Every reader tolerates the spellings stalkerhek handles plus the ones
/// Ministra's own source writes.
enum StalkerParse {
    // MARK: Lists

    /// The rows of a list answer: `js` as an array, `js.data` as an array, or
    /// `js.data` as an object of rows (some `get_epg_info` answers).
    static func rows(_ js: JSONValue) -> [JSONValue] {
        if let array = js.array { return array }
        if let data = js["data"] {
            if let array = data.array { return array }
            if data.object != nil { return data.elements.flatMap { $0.array ?? [$0] } }
        }
        return []
    }

    static func listPage(_ js: JSONValue) -> StalkerListPage {
        if let array = js.array { return StalkerListPage(items: array, totalItems: nil, pageSize: nil) }
        return StalkerListPage(items: rows(js), totalItems: js["total_items"]?.int, pageSize: js["max_page_items"]?.int)
    }

    /// `p` for our 0-based page. Ministra's `AjaxResponse` reads `p=0` as
    /// "the page holding the last-watched item" and `p=N` as page N-1 —
    /// which is why stalkerhek, sending `p=0` first, has to de-duplicate.
    /// We send what a MAG box sends: 1 for the first page.
    static func portalPage(_ page: Int) -> String {
        String(max(page, 0) + 1)
    }

    // MARK: Categories

    static func categories(_ js: JSONValue, kind: ContentKind) -> [RemoteCategory] {
        var categories: [RemoteCategory] = []
        for (index, row) in rows(js).enumerated() {
            guard let id = row.string("id"), id != "*" else { continue } // "*" is "All"
            let name = row.string("title", "name", "alias") ?? id
            categories.append(RemoteCategory(id: id, name: name, kind: kind, sortOrder: row.int("number") ?? index))
        }
        return categories
    }

    /// stalkerhek's rule for telling a series category inside the movie
    /// module: "Series", "TV Shows", "Season", "… TV".
    static func isSeriesStyleCategory(_ name: String) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowered.isEmpty else { return false }
        if ["series", "tv show", "tv series", "season"].contains(where: lowered.contains) { return true }
        return lowered.hasPrefix("tv ") || lowered.hasSuffix(" tv")
    }

    // MARK: Channels

    static func channels(_ js: JSONValue, api: URL) -> [RemoteChannel] {
        rows(js).compactMap { channel($0, api: api) }
    }

    /// One `get_all_channels` row: name, cmd, logo, tv_genre_id, cmds[0].id
    /// and ch_id (verified), plus number and the archive flags.
    static func channel(_ row: JSONValue, api: URL) -> RemoteChannel? {
        let firstCommand = row["cmds"]?.array?.first
        guard let name = row.string("name"),
              let command = row.string("cmd") ?? firstCommand?.string("url"),
              let id = row.string("id") ?? firstCommand?.string("ch_id")
        else { return nil }
        let hasArchive = row.truthy("enable_tv_archive", "tv_archive", "archive")
        return RemoteChannel(
            id: id,
            number: row.int("number"),
            name: name,
            logoURL: StalkerPortal.resolveAsset(row.string("logo"), api: api, logoDirectory: true),
            categoryID: row.string("tv_genre_id"),
            guideChannelID: firstCommand?.string("ch_id") ?? id,
            hasArchive: hasArchive,
            archiveDays: archiveDays(row.int("tv_archive_duration"), hasArchive: hasArchive),
            command: command,
            formatHint: lastWord(of: command).map { StreamFormatHint.guess(fromURL: $0) } ?? .unknown
        )
    }

    /// Ministra keeps `tv_archive_duration` in hours (168 for a week); some
    /// portals write days. Anything over a month is read as hours.
    static func archiveDays(_ duration: Int?, hasArchive: Bool) -> Int {
        guard hasArchive else { return 0 }
        guard let duration, duration > 0 else { return 7 }
        return duration > 31 ? Int((Double(duration) / 24).rounded(.up)) : duration
    }

    // MARK: Links

    /// The last space-separated word of a `cmd`, which drops an `ffmpeg` or
    /// `ffrt` prefix (verified). Nil when there's no word.
    static func lastWord(of command: String) -> String? {
        command.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)
    }

    /// The URL in a live `create_link` answer: the last word of `js.cmd`.
    static func liveLink(_ js: JSONValue) -> String? {
        let js = js.array?.last ?? js
        guard let command = js.string("cmd"), let word = lastWord(of: command), word.contains("://") else { return nil }
        return word
    }

    /// The URL in a movie or episode `create_link` answer, in stalkerhek's
    /// order: `js.url`; else an http URL in `js.cmd`; else `play/movie.php`
    /// built from `js.id` and `js.play_token` (verified).
    static func vodLink(_ js: JSONValue, streamServerBase: String?, mac: String, linkType: String) -> String? {
        // Ministra prepends advert entries as `[[ad], link]`; the link is last.
        let js = js.array?.last ?? js
        if let url = js.string("url"), let word = lastWord(of: url), word.contains("://") { return word }
        if let command = js.string("cmd"), let word = lastWord(of: command), word.lowercased().hasPrefix("http") { return word }
        if let id = js.string("id"), let token = js.string("play_token"), let base = streamServerBase {
            let stream = id.contains(".") ? id : id + ".mp4"
            return base + "/play/movie.php?" + QueryEncoding.query([("mac", mac), ("stream", stream), ("play_token", token), ("type", linkType)])
        }
        return nil
    }

    /// The `cmd` that plays a movie on a portal that keeps its video in file
    /// rows (Ministra 5; verified): `/media/file_<file id>.mpg` for its best
    /// file (highest `quality`, the first of equals). Nil when the rows
    /// aren't files: a portal without them answers with nothing, or with
    /// movies.
    static func movieFileCommand(_ rows: [JSONValue], movieID: String) -> String? {
        let files = rows.filter { $0.truthy("is_file") || $0.string("video_id") == movieID }
        var best: JSONValue?
        for file in files where file.string("id") != nil {
            if best == nil || (file.int("quality") ?? 0) > (best?.int("quality") ?? 0) { best = file }
        }
        guard let id = best?.string("id") else { return nil }
        return "/media/file_\(id).mpg"
    }

    /// Prepares a movie `cmd` for `create_link`. stalkerhek wraps a `cmd`
    /// with no leading `/` or `ffmpeg` as `/media/file_<cmd>.mpg`; that is
    /// right for a bare file id, but many portals send a base64 JSON `cmd`
    /// (`eyJ0eXBlIjoibW92aWUi…`) or a URL, which must go back untouched.
    static func movieCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if trimmed.hasPrefix("/") || lowered.hasPrefix("ffmpeg") || lowered.hasPrefix("ffrt") || lowered.hasPrefix("auto ")
            || trimmed.contains("://") || trimmed.contains(" ") || isBase64JSON(trimmed) {
            return trimmed
        }
        return "/media/file_\(trimmed).mpg"
    }

    private static func isBase64JSON(_ text: String) -> Bool {
        guard text.hasPrefix("eyJ") || text.hasPrefix("ewo") || text.hasPrefix("e30") else { return false }
        return Data(base64Encoded: Base64.padded(text)) != nil
    }

    // MARK: Guide

    /// A short guide (`get_short_epg`, `get_epg_info`): an array in `js`,
    /// `js.epg` or `js.data` (verified), or `js.data` keyed by channel id.
    /// Times are Unix numbers or wall-clock text in the portal's zone.
    static func programmes(_ js: JSONValue, guideChannelID: String, timeZone: TimeZone) -> [RemoteProgramme] {
        var items = js.array ?? js["epg"]?.array ?? js["data"]?.array ?? []
        if items.isEmpty, let data = js["data"], let object = data.object {
            items = object[guideChannelID]?.array ?? data.elements.flatMap { $0.array ?? [] }
        }
        return items.compactMap { programme($0, guideChannelID: guideChannelID, timeZone: timeZone) }
            .sorted { $0.start < $1.start }
    }

    static func programme(_ row: JSONValue, guideChannelID: String, timeZone: TimeZone) -> RemoteProgramme? {
        // Unix timestamps first: they can't be misread across a zone change.
        guard let start = date(in: row, keys: ["start_timestamp", "start", "from", "time"], timeZone: timeZone) else { return nil }
        var end = date(in: row, keys: ["stop_timestamp", "end", "stop", "to", "time_to"], timeZone: timeZone)
        if end == nil, let seconds = row.int("duration"), seconds > 0 { end = start.addingTimeInterval(TimeInterval(seconds)) }
        guard let end, end > start else { return nil }
        return RemoteProgramme(
            guideChannelID: row.string("ch_id") ?? guideChannelID,
            start: start,
            end: end,
            title: row.string("name", "title", "progname", "program") ?? "—",
            summary: row.string("descr", "description", "desc", "short_description", "plot"),
            category: row.string("category", "genre", "categories"),
            hasArchive: row.truthy("mark_archive", "has_archive")
        )
    }

    private static func date(in row: JSONValue, keys: [String], timeZone: TimeZone) -> Date? {
        for key in keys {
            if let date = ProviderTime.date(row[key], timeZone: timeZone) { return date }
        }
        return nil
    }

    // MARK: Movies and series

    static func movie(_ row: JSONValue, api: URL, timeZone: TimeZone) -> RemoteMovie? {
        guard let id = row.string("id"), let name = row.string("name", "o_name") else { return nil }
        return RemoteMovie(
            id: id,
            name: name,
            categoryID: row.string("category_id"),
            posterURL: poster(row, api: api),
            year: ProviderTime.year(in: row.string("year", "released", "release_date")),
            plot: row.string("description", "plot"),
            rating: rating(row),
            durationSeconds: duration(row),
            containerExtension: row.string("container_extension"),
            addedAt: ProviderTime.date(row["added"], timeZone: timeZone),
            genre: row.string("genres_str", "genre"),
            cast: row.string("actors", "cast"),
            director: row.string("director"),
            command: row.string("cmd")
        )
    }

    static func series(_ row: JSONValue, api: URL, timeZone: TimeZone) -> RemoteSeries? {
        guard let id = row.string("id"), let name = row.string("name", "o_name") else { return nil }
        return RemoteSeries(
            id: id,
            name: name,
            categoryID: row.string("category_id"),
            posterURL: poster(row, api: api),
            plot: row.string("description", "plot"),
            year: ProviderTime.year(in: row.string("year", "released", "release_date")),
            rating: rating(row),
            addedAt: ProviderTime.date(row["added"], timeZone: timeZone),
            genre: row.string("genres_str", "genre"),
            cast: row.string("actors", "cast"),
            command: row.string("cmd")
        )
    }

    static func poster(_ row: JSONValue, api: URL) -> URL? {
        StalkerPortal.resolveAsset(row.string("screenshot_uri", "cover_big", "cover", "pic", "logo"), api: api)
    }

    /// IMDb, then Kinopoisk, then a plain rating; "N/A" and 0 mean none.
    static func rating(_ row: JSONValue) -> Double? {
        for key in ["rating_imdb", "rating_kinopoisk", "rating"] {
            if let value = row[key]?.double, value > 0, value <= 10 { return value }
        }
        return nil
    }

    /// Ministra's `time` is minutes; other portals write `length` or
    /// `duration` as `01:45:00`.
    static func duration(_ row: JSONValue) -> Int? {
        ProviderTime.duration(row.first("time"), minutesWhenBare: true)
            ?? ProviderTime.duration(row.first("length", "duration"), minutesWhenBare: true)
    }

    /// The number in "Season 3", "Сезон 3", "S03", "Episode 4. Fog Bell".
    static func leadingNumber(in text: String?) -> Int? {
        guard let text else { return nil }
        var digits = ""
        for character in text {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    /// "Episode 4. Fog Bell" → "Fog Bell"; "Episode 4" stays as it is.
    static func episodeTitle(_ name: String) -> String {
        let pattern = #"^\s*(episode|серия|ep\.?|e)\s*\d+\s*[.:\-–—]\s*"#
        guard let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return name }
        let rest = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }
}

/// Base64 as providers send it: sometimes unpadded, sometimes URL-safe.
enum Base64 {
    static func padded(_ text: String) -> String {
        var normalised = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalised.count % 4
        if remainder > 0 { normalised += String(repeating: "=", count: 4 - remainder) }
        return normalised
    }

    /// The text `value` encodes, when it decodes cleanly to printable UTF-8;
    /// nil otherwise, so a plain title is never mangled (Xtream short guides).
    static func decodedText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Providers encode with PHP's base64_encode, which always pads, so a
        // length that isn't a multiple of 4 is plain text.
        guard trimmed.count >= 4, trimmed.count % 4 == 0,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=-_".contains($0)) }),
              let data = Data(base64Encoded: padded(trimmed)),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }),
              !text.unicodeScalars.contains(where: { $0.value == 0xFFFD })
        else { return nil }
        return text
    }
}

// MARK: - Session, series and account readers

extension StalkerParse {
    /// Signed in when `get_profile` gives the account an id (verified in
    /// stalkerhek). Some portals answer an unknown MAC with `id: 0` or null.
    static func profileIsSignedIn(_ js: JSONValue) -> Bool {
        guard let id = js.string("id") else { return false }
        return id != "0"
    }

    /// Episode rows of one season (`get_ordered_list` with a `season_id`).
    /// The number is `series_number`, else the number in the name, else the
    /// row's position; it, not the provider's id, goes into item keys.
    static func episodes(_ rows: [JSONValue], seriesID: String, season: Int, seasonID: String? = nil, api: URL) -> [RemoteEpisode] {
        rows.enumerated().compactMap { index, row in
            guard let id = row.string("id") else { return nil }
            let name = row.string("name") ?? ""
            let number = row.int("series_number", "episode_number") ?? leadingNumber(in: name) ?? index + 1
            return RemoteEpisode(
                id: id,
                seriesID: seriesID,
                season: season,
                number: number,
                title: name.isEmpty ? "Episode \(number)" : episodeTitle(name),
                plot: row.string("description", "plot"),
                durationSeconds: duration(row),
                containerExtension: row.string("container_extension"),
                posterURL: poster(row, api: api),
                command: row.string("cmd"),
                seasonID: row.string("season_id") ?? seasonID
            )
        }
    }

    /// Episodes of a portal that lists them only as numbers on the season
    /// row (`series: [1, 2, 3]`) and plays each as the season's `cmd` plus
    /// `series=<n>`.
    static func numberedEpisodes(_ seasonRow: JSONValue, seriesID: String, season: Int) -> [RemoteEpisode] {
        guard let numbers = seasonRow["series"]?.array?.compactMap(\.int), !numbers.isEmpty,
              let command = seasonRow.string("cmd")
        else { return [] }
        let seasonID = seasonRow.string("id") ?? String(season)
        return numbers.map { number in
            RemoteEpisode(
                id: "\(seasonID):\(number)",
                seriesID: seriesID,
                season: season,
                number: number,
                title: "Episode \(number)",
                command: command
            )
        }
    }

    /// `2026-10-24` in the portal's zone, the `date` of `get_simple_data_table`.
    static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The `id` of the guide row that starts at `start` (within five
    /// minutes: portals round), for a `tv_archive` link.
    static func programmeID(in rows: [JSONValue], startingAt start: Date, timeZone: TimeZone) -> String? {
        var best: (id: String, gap: TimeInterval)?
        for row in rows {
            guard let id = row.string("id"),
                  let programme = programme(row, guideChannelID: "", timeZone: timeZone)
            else { continue }
            let gap = abs(programme.start.timeIntervalSince(start))
            if gap <= 300, gap < (best?.gap ?? .infinity) { best = (id, gap) }
        }
        return best?.id
    }

    /// The account from `get_profile` and `account_info/get_main_info`
    /// (unverified). Expiry fields differ per portal; many resellers put the
    /// date in `phone` ("January 15, 2027, 4:31 pm"), so that one is read
    /// only as a written date, never as a number.
    static func account(profile: JSONValue?, mainInfo: JSONValue?, timeZone: TimeZone, now: Date) -> AccountInfo {
        var expiresAt: Date?
        let sources = [mainInfo, profile].compactMap { $0 }.filter { $0.object != nil }
        search: for source in sources {
            for key in ["end_date", "expire_billing_date", "expire_date", "exp_date", "expires", "expiry", "tariff_expired_date"] {
                guard let value = source[key] else { continue }
                if let date = ProviderTime.unix(value) ?? value.string.flatMap({ ProviderTime.looseDate($0, timeZone: timeZone) }) {
                    expiresAt = date
                    break search
                }
            }
            if let phone = source.string("phone"), let date = ProviderTime.looseDate(phone, timeZone: timeZone) {
                expiresAt = date
                break search
            }
        }
        let blocked = profile?.truthy("blocked") == true
        let message = profile?.string("block_msg", "msg") ?? mainInfo?.string("msg", "message")
        let status: AccountStatus
        if blocked {
            status = .disabled
        } else if let expiresAt, expiresAt < now {
            status = .expired
        } else {
            status = .active
        }
        return AccountInfo(status: status, expiresAt: expiresAt, message: message)
    }
}
