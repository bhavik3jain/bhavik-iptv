import Foundation

/// XMLTV guides (Xtream `xmltv.php`, an M3U playlist's `x-tvg-url`, a typed
/// guide URL), read as a stream: downloaded to a file, un-gzipped on the fly
/// when it's compressed, and parsed with a streaming `XMLParser` on its own
/// thread, so a several-hundred-megabyte guide never sits in memory (SRC-3,
/// technical spec, Big files).
public enum XMLTVGuide {
    /// The guide at `url` as a stream of programmes. File URLs are read in
    /// place. Nothing is fetched until the stream is iterated.
    public static func programmes(
        from url: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:]
    ) -> AsyncThrowingStream<RemoteProgramme, Error> {
        ProgrammeStream.make { channel in
            var request = URLRequest(url: url, timeoutInterval: HTTP.downloadTimeout)
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            let download = try await HTTP.download(request, session: session)
            defer { if download.isTemporary { try? FileManager.default.removeItem(at: download.file) } }
            guard (200..<300).contains(download.status) else {
                let text = (try? Data(contentsOf: download.file)).flatMap { HTTP.plainText(from: $0) }
                throw SourceError(download.status == 401 || download.status == 403 ? .authenticationFailed : .badResponse,
                                  providerMessage: text, detail: "Guide answered HTTP \(download.status)")
            }
            try await parse(file: download.file, into: channel)
        }
    }

    /// Parses a guide held in memory (tests, small guides).
    static func programmes(from data: Data) throws -> [RemoteProgramme] {
        var programmes: [RemoteProgramme] = []
        let parser = XMLParser(data: GzipDecoder.isGzip(data.prefix(2)) ? try GzipDecoder.decompress(data) : data)
        let delegate = XMLTVParserDelegate { programmes.append($0); return true }
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        if !parser.parse(), let error = parser.parserError, !delegate.sawEnd {
            throw SourceError(.badResponse, detail: "XMLTV: \(error.localizedDescription)")
        }
        return programmes
    }

    /// Parses `file` on a dedicated thread (XMLParser blocks while it reads),
    /// sending each programme into `channel`.
    static func parse(file: URL, into channel: ProgrammeChannel) async throws {
        let isGzip: Bool = {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            return GzipDecoder.isGzip((try? handle.read(upToCount: 2)) ?? Data())
        }()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread {
                do {
                    try parseSynchronously(file: file, gzip: isGzip, channel: channel)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "Hearth XMLTV"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private static func parseSynchronously(file: URL, gzip: Bool, channel: ProgrammeChannel) throws {
        guard let fileStream = InputStream(url: file) else {
            throw SourceError(.badResponse, detail: "XMLTV: the downloaded guide can't be opened")
        }
        let stream: InputStream = gzip ? GunzipInputStream(source: fileStream) : fileStream
        let parser = XMLParser(stream: stream)
        let delegate = XMLTVParserDelegate { channel.send($0) }
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let succeeded = parser.parse()
        if channel.isCancelled || delegate.stoppedByConsumer { throw CancellationError() }
        if !succeeded, !delegate.sawEnd {
            if let gzipError = stream.streamError {
                throw SourceError(.badResponse, detail: "XMLTV: the compressed guide is damaged (\(gzipError))")
            }
            let line = parser.lineNumber
            throw SourceError(.badResponse, detail: "XMLTV: \(parser.parserError?.localizedDescription ?? "parse error") at line \(line)")
        }
    }
}

/// Collects `<programme>` elements. Only the first `title`, `desc` and
/// `category` count — guides repeat them per language.
final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private enum Field { case title, subtitle, summary, category }

    private let onProgramme: (RemoteProgramme) -> Bool
    private var channel: String?
    private var start: Date?
    private var stop: Date?
    private var title: String?
    private var subtitle: String?
    private var summary: String?
    private var category: String?
    private var capturing: Field?
    private var text = ""
    private(set) var stoppedByConsumer = false
    /// The closing `</tv>` was seen; errors after it (trailing junk) don't count.
    private(set) var sawEnd = false

    /// `onProgramme` returns false to stop parsing.
    init(onProgramme: @escaping (RemoteProgramme) -> Bool) {
        self.onProgramme = onProgramme
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "programme":
            channel = attributes["channel"]
            start = attributes["start"].flatMap(ProviderTime.xmltv)
            stop = attributes["stop"].flatMap(ProviderTime.xmltv)
            title = nil
            subtitle = nil
            summary = nil
            category = nil
        case "title" where channel != nil && title == nil: begin(.title)
        case "sub-title" where channel != nil && subtitle == nil: begin(.subtitle)
        case "desc" where channel != nil && summary == nil: begin(.summary)
        case "category" where channel != nil && category == nil: begin(.category)
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturing != nil, let string = String(data: CDATABlock, encoding: .utf8) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "title", "sub-title", "desc", "category":
            guard let field = capturing else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            capturing = nil
            text = ""
            guard !value.isEmpty else { return }
            switch field {
            case .title: title = value
            case .subtitle: subtitle = value
            case .summary: summary = value
            case .category: category = value
            }
        case "programme":
            defer { channel = nil }
            guard let channel, let start else { return }
            let end = stop ?? start.addingTimeInterval(1800)
            guard end > start else { return }
            let programme = RemoteProgramme(
                guideChannelID: channel,
                start: start,
                end: end,
                title: title ?? subtitle ?? "—",
                summary: summary ?? (title != nil ? subtitle : nil),
                category: category
            )
            if !onProgramme(programme) {
                stoppedByConsumer = true
                parser.abortParsing()
            }
        case "tv":
            sawEnd = true
        default:
            break
        }
    }

    private func begin(_ field: Field) {
        capturing = field
        text = ""
    }
}
