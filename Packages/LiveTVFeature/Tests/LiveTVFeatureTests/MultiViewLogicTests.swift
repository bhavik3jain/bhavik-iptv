import CoreGraphics
import Foundation
import PlayerKit
import SourceKit
import Testing
@testable import LiveTVFeature

@Suite struct MultiViewArrangementTests {
    @Test func oneAndTwoShareTheTwoTileModel() {
        #expect(MultiViewArrangement.allCases == [.one, .two, .three, .four])
        #expect(MultiViewArrangement.one.modelLayout == .two)
        #expect(MultiViewArrangement.two.modelLayout == .two)
        #expect(MultiViewArrangement.three.modelLayout == .three)
        #expect(MultiViewArrangement.four.modelLayout == .four)
        #expect(MultiViewArrangement.allCases.map(\.id) == ["one", "two", "three", "four"])
    }
}

@Suite struct MultiViewGridGeometryTests {
    private func geometry(_ tiles: Int, _ width: CGFloat, _ height: CGFloat, spacing: CGFloat = 0) -> MultiViewGridGeometry {
        MultiViewGridGeometry.make(tileCount: tiles, available: CGSize(width: width, height: height), spacing: spacing)
    }

    /// 16:9 sizes come out of a division, so they are compared to a
    /// thousandth of a point.
    private func check(_ g: MultiViewGridGeometry, columns: Int, width: CGFloat, height: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(g.columns == columns, sourceLocation: sourceLocation)
        #expect(abs(g.tileSize.width - width) < 0.001, "width \(g.tileSize.width)", sourceLocation: sourceLocation)
        #expect(abs(g.tileSize.height - height) < 0.001, "height \(g.tileSize.height)", sourceLocation: sourceLocation)
    }

    @Test func oneTileFillsTheWidthOrTheHeight() {
        check(geometry(1, 1600, 900), columns: 1, width: 1600, height: 900)
        check(geometry(1, 1600, 450), columns: 1, width: 800, height: 450)
    }

    @Test func twoTilesSitSideBySideWhenTheSpaceIsWide() {
        check(geometry(2, 1600, 500), columns: 2, width: 800, height: 450)
    }

    @Test func twoTilesStackWhenTheSpaceIsTall() {
        // A phone, or iPhone Duo's inner display in portrait.
        check(geometry(2, 400, 900), columns: 1, width: 400, height: 225)
    }

    @Test func spacingComesOutOfTheTiles() {
        check(geometry(2, 1608, 500, spacing: 8), columns: 2, width: 800, height: 450)
        check(geometry(2, 400, 908, spacing: 8), columns: 1, width: 400, height: 225)
    }

    @Test func fourTilesMakeAGridARowOrAColumn() {
        check(geometry(4, 1600, 900), columns: 2, width: 800, height: 450)
        check(geometry(4, 1600, 225), columns: 4, width: 400, height: 225)
        check(geometry(4, 400, 1000), columns: 1, width: 400, height: 225)
    }

    @Test func threeTilesRoundTheRowsUp() {
        // Two over one, the third centred.
        check(geometry(3, 1600, 900), columns: 2, width: 800, height: 450)
    }

    @Test func threeTilesMakeARowWhenTheSpaceIsWide() {
        check(geometry(3, 1800, 340), columns: 3, width: 600, height: 337.5)
        // Never four columns for three tiles.
        check(geometry(3, 2400, 300), columns: 3, width: 533.333, height: 300)
    }

    @Test func aTieKeepsFewerColumns() {
        // Stacked and side by side both make 800 × 450 tiles here; the grid
        // only changes for a real gain, so it doesn't flip on a resize.
        check(geometry(2, 1600, 900), columns: 1, width: 800, height: 450)
    }

    @Test func tilesAreAlways16By9() {
        for (tiles, width, height) in [(1, 1000.0, 300.0), (2, 1366.0, 1024.0), (4, 844.0, 390.0), (3, 2000.0, 700.0)] {
            let g = geometry(tiles, width, height, spacing: 6)
            #expect(g.tileSize.width > 0)
            #expect(abs(g.tileSize.width / g.tileSize.height - 16 / 9) < 0.0001)
        }
    }

    @Test func noSpaceMeansNoTiles() {
        #expect(geometry(2, 0, 0) == MultiViewGridGeometry(columns: 1, tileSize: .zero))
        #expect(geometry(4, 10, 10, spacing: 20).tileSize == .zero)
    }

    @Test func noTilesIsTreatedAsOne() {
        #expect(geometry(0, 1600, 900) == geometry(1, 1600, 900))
        #expect(geometry(-3, 1600, 900) == geometry(1, 1600, 900))
    }
}

@Suite struct SourceLimitsTests {
    @Test func xtreamReportsItsOwnLimit() {
        #expect(SourceLimits.limit(kindRaw: "xtream", maxStreams: 1, accountMaxConnections: 3) == 3)
    }

    @Test func aZeroOrMissingReportFallsBackToTheOwnersSetting() {
        #expect(SourceLimits.limit(kindRaw: "xtream", maxStreams: 2, accountMaxConnections: 0) == 2)
        #expect(SourceLimits.limit(kindRaw: "xtream", maxStreams: 2, accountMaxConnections: nil) == 2)
        #expect(SourceLimits.limit(kindRaw: "xtream", maxStreams: 0, accountMaxConnections: nil) == nil)
    }

    @Test func onlyXtreamsReportCounts() {
        #expect(SourceLimits.limit(kindRaw: "stalker", maxStreams: 1, accountMaxConnections: 5) == 1)
        #expect(SourceLimits.limit(kindRaw: "m3u", maxStreams: 0, accountMaxConnections: 5) == nil)
    }

    @Test func zeroMeansUnlimited() {
        #expect(SourceLimits.limit(kindRaw: "stalker", maxStreams: 0, accountMaxConnections: nil) == nil)
        #expect(SourceLimits.limit(kindRaw: "m3u", maxStreams: -1, accountMaxConnections: nil) == nil)
    }

    @Test func defaultsAreOnePerMacForStalkerAndUnlimitedOtherwise() {
        #expect(SourceLimits.defaultMaxStreams(kindRaw: "stalker") == 1)
        #expect(SourceLimits.defaultMaxStreams(kindRaw: "xtream") == 0)
        #expect(SourceLimits.defaultMaxStreams(kindRaw: "m3u") == 0)
        #expect(SourceLimits.defaultMaxStreams(kindRaw: "") == 0)
    }
}

@Suite struct StreamLimitAdviceTests {
    private func state(_ name: String, inUse: Int, limit: Int?) -> SourceStreamState {
        SourceStreamState(sourceID: UUID(), name: name, inUse: inUse, limit: limit)
    }

    @Test func fullnessNeedsALimit() {
        #expect(!state("A", inUse: 9, limit: nil).isFull)
        #expect(!state("A", inUse: 1, limit: 2).isFull)
        #expect(state("A", inUse: 2, limit: 2).isFull)
        #expect(state("A", inUse: 3, limit: 2).isFull)
    }

    @Test func noReasonWhileEverySourceHasRoom() {
        #expect(StreamLimitAdvice.emptyTileReason([]) == nil)
        #expect(StreamLimitAdvice.emptyTileReason([state("A", inUse: 1, limit: 2), state("B", inUse: 5, limit: nil)]) == nil)
    }

    @Test func oneFullSourceWithAnotherOpen() {
        let reason = StreamLimitAdvice.emptyTileReason([state("Provider A", inUse: 1, limit: 1), state("Family playlist", inUse: 0, limit: nil)])
        #expect(reason == "Provider A is at its stream limit. Pick a channel from Family playlist, or swap a tile.")
    }

    @Test func oneFullSourceAlone() {
        let reason = StreamLimitAdvice.emptyTileReason([state("Provider A", inUse: 1, limit: 1)])
        #expect(reason == "Provider A is at its stream limit. Swap a tile to watch another of its channels.")
    }

    @Test func twoFullSourcesAreBothAtTheirLimits() throws {
        // The mockup's line. List joining follows the locale, so the names
        // are checked separately from the sentence around them.
        let reason = StreamLimitAdvice.emptyTileReason([
            state("Provider A", inUse: 1, limit: 1),
            state("Provider B", inUse: 2, limit: 2),
            state("Family playlist", inUse: 1, limit: nil),
        ])
        let text = try #require(reason)
        #expect(text.hasPrefix("Provider A"))
        #expect(text.contains("Provider B are both at their stream limits. Pick a channel from Family playlist, or swap a tile."))

        let none = try #require(StreamLimitAdvice.emptyTileReason([state("Provider A", inUse: 1, limit: 1), state("Provider B", inUse: 2, limit: 2)]))
        #expect(none.hasSuffix("Provider B are both at their stream limits. Swap a tile to watch something else."))
    }

    @Test func threeOrMoreFullSourcesAreAllAtTheirLimits() throws {
        let full = [state("A", inUse: 1, limit: 1), state("B", inUse: 1, limit: 1), state("C", inUse: 1, limit: 1)]
        let alone = try #require(StreamLimitAdvice.emptyTileReason(full))
        #expect(alone.hasSuffix("C are all at their stream limits. Swap a tile to watch something else."))
        let withOpen = try #require(StreamLimitAdvice.emptyTileReason(full + [state("D", inUse: 0, limit: 4)]))
        #expect(withOpen.hasSuffix("C are all at their stream limits. Pick a channel from D, or swap a tile."))
    }

    @Test func thePickersNoteOnlyOnAFullSource() {
        #expect(StreamLimitAdvice.channelNote(state("Provider B", inUse: 2, limit: 2)) == "Provider B is at its limit (2 of 2)")
        #expect(StreamLimitAdvice.channelNote(state("Provider B", inUse: 1, limit: 2)) == nil)
        #expect(StreamLimitAdvice.channelNote(state("Provider B", inUse: 7, limit: nil)) == nil)
    }
}

@Suite struct StreamDescriptorsTests {
    @Test(arguments: [StreamFormatHint.hls, .mpegts, .mp4, .mkv, .unknown])
    func everyFormatHintCarriesAcross(hint: StreamFormatHint) {
        #expect(StreamDescriptors.format(hint).rawValue == hint.rawValue)
    }

    @Test func aDescriptorKeepsTheLinksHeadersAndLiveness() {
        let link = StreamLink(url: URL(string: "https://example.com/live/101.ts")!, headers: ["User-Agent": "Hearth"], formatHint: .mpegts, isLive: true)
        let descriptor = StreamDescriptors.descriptor(for: link)
        #expect(descriptor.url == link.url)
        #expect(descriptor.headers == ["User-Agent": "Hearth"])
        #expect(descriptor.format == .mpegts)
        #expect(descriptor.isLive)
        #expect(descriptor.startPosition == nil)
    }
}
