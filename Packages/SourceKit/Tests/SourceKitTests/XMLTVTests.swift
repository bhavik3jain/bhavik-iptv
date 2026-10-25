import Foundation
import Testing
@testable import SourceKit

/// XMLTV guides: time offsets, first-language fields, CDATA and entities,
/// gzip through the Compression framework, and the streaming path (SRC-3).
@Suite struct XMLTVTests {
    @Test func programmesWithEveryOffsetSpelling() throws {
        let programmes = try XMLTVGuide.programmes(from: Fixture.data("xmltv/guide.xml"))
        #expect(programmes.count == 5) // the one that ends before it starts is dropped

        let bulletin = programmes[0]
        #expect(bulletin.guideChannelID == "cityline.news")
        #expect(bulletin.start == utc(2026, 10, 24, 20))
        #expect(bulletin.end == utc(2026, 10, 24, 21))
        #expect(bulletin.title == "Evening Bulletin") // the first title, not the French one
        #expect(bulletin.summary == "Tonight's news.")
        #expect(bulletin.category == "News")

        // +0100 and -0500 offsets.
        #expect(programmes[1].start == utc(2026, 10, 24, 20))
        #expect(programmes[1].summary == "Friday edition") // sub-title stands in for a missing desc
        #expect(programmes[2].start == utc(2026, 10, 24, 20, 30))
        #expect(programmes[2].end == utc(2026, 10, 24, 23, 30))
        #expect(programmes[2].title == "Premier Cricket · Final, 2nd innings") // CDATA
        #expect(programmes[2].summary == "Live & uninterrupted.") // entity decoded

        // No offset is UTC; no stop is half an hour.
        #expect(programmes[3].start == utc(2026, 10, 24, 22, 30))
        #expect(programmes[4].end == utc(2026, 10, 24, 23, 30))
    }

    @Test func xmltvTimes() {
        #expect(ProviderTime.xmltv("20261024200000 +0000") == utc(2026, 10, 24, 20))
        #expect(ProviderTime.xmltv("20261024200000 +0530") == utc(2026, 10, 24, 14, 30))
        #expect(ProviderTime.xmltv("20261024200000 -08:00") == utc(2026, 10, 25, 4))
        #expect(ProviderTime.xmltv("202610242000") == utc(2026, 10, 24, 20))
        #expect(ProviderTime.xmltv("20261324200000") == nil)
        #expect(ProviderTime.xmltv("tomorrow") == nil)
    }

    // MARK: Gzip

    @Test func gzipDecodesToTheSameBytes() throws {
        let plain = Fixture.data("xmltv/guide.xml")
        let packed = Fixture.data("xmltv/guide.xml.gz")
        #expect(GzipDecoder.isGzip(packed.prefix(2)))
        #expect(!GzipDecoder.isGzip(plain.prefix(2)))
        #expect(try GzipDecoder.decompress(packed) == plain)
    }

    /// Feeds `packed` `size` bytes at a time.
    func decode(_ packed: Data, chunk size: Int) throws -> Data {
        var decoder = GzipDecoder()
        var result = Data()
        var index = packed.startIndex
        while index < packed.endIndex {
            let next = min(index + size, packed.endIndex)
            try decoder.feed(packed[index..<next]) { result.append($0) }
            index = next
        }
        try decoder.finish()
        return result
    }

    @Test(arguments: [1, 7, 64, 4096])
    func gzipDecodesInAnyChunkSize(_ size: Int) throws {
        #expect(try decode(Fixture.data("xmltv/guide.xml.gz"), chunk: size) == Fixture.data("xmltv/guide.xml"))
    }

    /// Compression reads past the end of a member, so the next one is found
    /// by the trailer's CRC and length.
    @Test(arguments: [3, 9, 100, 100_000])
    func concatenatedGzipMembers(_ size: Int) throws {
        let packed = Fixture.data("xmltv/guide.xml.gz")
        let plain = Fixture.data("xmltv/guide.xml")
        #expect(try decode(packed + packed + packed, chunk: size) == plain + plain + plain)
    }

    @Test func crc32MatchesTheStandardCheckValue() {
        var crc = CRC32()
        Array("123456789".utf8).withUnsafeBufferPointer { crc.update($0) }
        #expect(crc.value == 0xCBF4_3926)
    }

    @Test func truncatedGzipIsAnError() {
        let packed = Fixture.data("xmltv/guide.xml.gz")
        #expect(throws: GzipDecoder.Failure.self) { try GzipDecoder.decompress(packed.prefix(packed.count / 2)) }
        #expect(throws: GzipDecoder.Failure.self) { try GzipDecoder.decompress(Data("plain text".utf8)) }
    }

    @Test func gzippedGuideInMemory() throws {
        let programmes = try XMLTVGuide.programmes(from: Fixture.data("xmltv/guide.xml.gz"))
        #expect(programmes.count == 5)
    }

    // MARK: Streaming

    @Test func streamsAGzippedFile() async throws {
        let stream = XMLTVGuide.programmes(from: Fixture.url("xmltv/guide.xml.gz"))
        var programmes: [RemoteProgramme] = []
        for try await programme in stream { programmes.append(programme) }
        #expect(programmes == (try XMLTVGuide.programmes(from: Fixture.data("xmltv/guide.xml"))))
    }

    @Test func streamsOverHTTP() async throws {
        let host = StubURLProtocol.makeHost("guide")
        let session = StubURLProtocol.session(host: host) { _ in .fixture("xmltv/guide.xml") }
        var count = 0
        for try await _ in XMLTVGuide.programmes(from: URL(string: "http://\(host)/guide.xml")!, session: session) { count += 1 }
        #expect(count == 5)
    }

    @Test func aBigGuideStreamsThroughTheBoundedBuffer() async throws {
        // More programmes than the hand-off buffer holds, so the parser
        // thread has to wait for the consumer.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        var xml = "<tv>"
        for index in 0..<5_000 {
            let start = utc(2026, 10, 24, 0).addingTimeInterval(TimeInterval(index * 60))
            let stamps = (formatter.string(from: start), formatter.string(from: start.addingTimeInterval(60)))
            xml += #"<programme start="\#(stamps.0) +0000" stop="\#(stamps.1) +0000" channel="c\#(index % 7)"><title>P\#(index)</title></programme>"#
        }
        xml += "</tv>"
        let file = FileManager.default.temporaryDirectory.appending(path: "hearth-test-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        for try await _ in XMLTVGuide.programmes(from: file) { count += 1 }
        #expect(count == 5_000)
    }

    @Test func stoppingEarlyEndsTheStream() async throws {
        var seen = 0
        for try await _ in XMLTVGuide.programmes(from: Fixture.url("xmltv/guide.xml")) {
            seen += 1
            if seen == 2 { break }
        }
        #expect(seen == 2)
    }

    @Test func aGuideServerErrorCarriesItsText() async {
        let host = StubURLProtocol.makeHost("guide")
        let session = StubURLProtocol.session(host: host) { _ in .text("Guide not available", status: 404) }
        let error = await sourceError {
            for try await _ in XMLTVGuide.programmes(from: URL(string: "http://\(host)/xmltv.php")!, session: session) {}
        }
        #expect(error?.code == .badResponse)
        #expect(error?.providerMessage == "Guide not available")
    }

    @Test func brokenXMLIsABadResponse() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hearth-test-\(UUID().uuidString).xml")
        try Data("<tv><programme start=\"20261024200000\" channel=\"a\"><title>Unclosed".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let error = await sourceError {
            for try await _ in XMLTVGuide.programmes(from: file) {}
        }
        #expect(error?.code == .badResponse)
    }
}
