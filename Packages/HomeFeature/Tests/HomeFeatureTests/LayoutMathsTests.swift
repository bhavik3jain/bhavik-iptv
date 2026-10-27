import Core
import CoreGraphics
import Testing
@testable import HomeFeature

@Suite struct HomeLayoutMetricsTests {
    @Test func theGutterWidensOnlyInAWideSidebarLayout() {
        #expect(HomeLayoutMetrics.gutter(layout: .compact, width: 1400) == HearthMetrics.screenPadding)
        #expect(HomeLayoutMetrics.gutter(layout: .sidebar, width: 466) == HearthMetrics.screenPadding)
        #expect(HomeLayoutMetrics.gutter(layout: .sidebar, width: 639.5) == HearthMetrics.screenPadding)
        #expect(HomeLayoutMetrics.gutter(layout: .sidebar, width: 640) == 32)
        #expect(HomeLayoutMetrics.gutter(layout: .sidebar, width: 1600) == 32)
    }

    @Test func theHeroPosterSitsBesideTheTextOnceThereIsRoom() {
        #expect(!HomeLayoutMetrics.heroShowsSidePoster(layout: .compact, contentWidth: 2000))
        #expect(!HomeLayoutMetrics.heroShowsSidePoster(layout: .sidebar, contentWidth: 519))
        #expect(HomeLayoutMetrics.heroShowsSidePoster(layout: .sidebar, contentWidth: 520))
    }

    @Test func homeStopsGrowingAtAReadableWidth() {
        #expect(HomeLayoutMetrics.readableWidth == 1120)
    }
}

@Suite struct PosterGridFitTests {
    @Test func columnsCountTheSpacingBetweenPostersOnly() {
        // Three 120-pt posters and two 16-pt gaps are exactly 392 pt.
        #expect(PosterGridFit.columns(width: 392, minimum: 120, spacing: 16) == 3)
        #expect(PosterGridFit.columns(width: 391, minimum: 120, spacing: 16) == 2)
        #expect(PosterGridFit.columns(width: 527, minimum: 120, spacing: 16) == 3)
        #expect(PosterGridFit.columns(width: 528, minimum: 120, spacing: 16) == 4)
    }

    @Test func alwaysAtLeastOneColumn() {
        #expect(PosterGridFit.columns(width: 50, minimum: 120, spacing: 16) == 1)
        #expect(PosterGridFit.columns(width: 0, minimum: 120, spacing: 16) == 1)
        #expect(PosterGridFit.columns(width: -10, minimum: 120, spacing: 16) == 1)
        #expect(PosterGridFit.columns(width: 400, minimum: 0, spacing: 16) == 1)
    }

    @Test func visibleCountIsCappedAtWholeRows() {
        #expect(PosterGridFit.visibleCount(total: 20, columns: 6, rows: 2) == 12)
        #expect(PosterGridFit.visibleCount(total: 7, columns: 6, rows: 2) == 7)
        #expect(PosterGridFit.visibleCount(total: 12, columns: 6, rows: 2) == 12)
        #expect(PosterGridFit.visibleCount(total: 0, columns: 6, rows: 2) == 0)
    }

    @Test func zeroColumnsOrRowsCountAsOne() {
        #expect(PosterGridFit.visibleCount(total: 20, columns: 0, rows: 2) == 2)
        #expect(PosterGridFit.visibleCount(total: 20, columns: 4, rows: 0) == 4)
    }
}

@Suite struct CardGridTests {
    @Test func noCardsNoRows() {
        let grid = CardGrid.rows([Int](), columns: 3, maxRows: 2)
        #expect(grid.rows.isEmpty)
        #expect(grid.hiddenCount == 0)
    }

    @Test func cardsWrapIntoRowsOfTheColumnCount() {
        let grid = CardGrid.rows(Array(1...5), columns: 3, maxRows: 2)
        #expect(grid.rows == [[1, 2, 3], [4, 5]])
        #expect(grid.hiddenCount == 0)
    }

    @Test func exactlyFullShowsEveryCard() {
        let grid = CardGrid.rows(Array(1...6), columns: 3, maxRows: 2)
        #expect(grid.rows == [[1, 2, 3], [4, 5, 6]])
        #expect(grid.hiddenCount == 0)
    }

    @Test func oneTooManyKeepsTheLastSlotForTheGuideCard() {
        let grid = CardGrid.rows(Array(1...7), columns: 3, maxRows: 2)
        #expect(grid.rows == [[1, 2, 3], [4, 5]])
        // The sixth slot is the "more in the guide" card: 6 and 7 are behind it.
        #expect(grid.hiddenCount == 2)
    }

    @Test func manyMoreNeverGrowsAThirdRow() {
        let grid = CardGrid.rows(Array(1...40), columns: 4, maxRows: 2)
        #expect(grid.rows.count == 2)
        #expect(grid.rows.flatMap { $0 } == Array(1...7))
        #expect(grid.hiddenCount == 33)
    }

    @Test func zeroColumnsOrRowsCountAsOne() {
        let grid = CardGrid.rows(Array(1...3), columns: 0, maxRows: 0)
        #expect(grid.rows.isEmpty)
        #expect(grid.hiddenCount == 3)
        let single = CardGrid.rows([1], columns: 0, maxRows: 0)
        #expect(single.rows == [[1]])
        #expect(single.hiddenCount == 0)
    }

    @Test func favoritesWrapInTheSidebarFromThreeAcross() {
        #expect(!CardGrid.wrapsFavorites(layout: .compact, columns: 6))
        #expect(!CardGrid.wrapsFavorites(layout: .sidebar, columns: 2))
        #expect(CardGrid.wrapsFavorites(layout: .sidebar, columns: 3))
    }
}
