import Foundation
import Testing
@testable import LiveTVFeature

@Suite struct TVTileActionTests {
    @Test func anEmptyTileTakesAChannelWhateverElseIsTrue() {
        #expect(TVTileAction.onSelect(isEmpty: true, hasFailed: false, hasSound: false) == .addChannel)
        #expect(TVTileAction.onSelect(isEmpty: true, hasFailed: true, hasSound: true) == .addChannel)
    }

    @Test func aFailedTileTriesAgainEvenWithTheSound() {
        #expect(TVTileAction.onSelect(isEmpty: false, hasFailed: true, hasSound: false) == .retry)
        #expect(TVTileAction.onSelect(isEmpty: false, hasFailed: true, hasSound: true) == .retry)
    }

    @Test func selectTakesThePlayingTileTheSoundAndThenFullScreen() {
        #expect(TVTileAction.onSelect(isEmpty: false, hasFailed: false, hasSound: false) == .giveSound)
        #expect(TVTileAction.onSelect(isEmpty: false, hasFailed: false, hasSound: true) == .fullScreen)
    }

    @Test func aFocusedTileAlwaysSaysWhatSelectDoes() {
        for action in [TVTileAction.addChannel, .retry, .giveSound, .fullScreen] {
            #expect(action.hint.hasPrefix("Select"))
        }
    }

    @Test func onlyAPlayingTileHasAHoldMenuToMention() {
        #expect(!TVTileAction.addChannel.hint.contains("Hold"))
        for action in [TVTileAction.retry, .giveSound, .fullScreen] {
            #expect(action.hint.contains("Hold"))
        }
    }
}

@Suite struct TVMultiViewFocusRulesTests {
    private typealias Slot = TVMultiViewFocusRules.Slot

    @Test func opensOnTheFirstTileWaitingForAChannel() {
        let slots = [Slot(id: 0, isEmpty: true), Slot(id: 1, isEmpty: true)]
        #expect(TVMultiViewFocusRules.initial(slots: slots, audibleTileID: nil) == .tile(0))
    }

    @Test func aChannelBroughtFromThePlayerMovesFocusToTheNextEmptyTile() {
        let slots = [Slot(id: 0, isEmpty: false), Slot(id: 1, isEmpty: true), Slot(id: 2, isEmpty: true)]
        #expect(TVMultiViewFocusRules.initial(slots: slots, audibleTileID: 0) == .tile(1))
    }

    @Test func withEveryTilePlayingItOpensOnTheOneWithTheSound() {
        let slots = [Slot(id: 0, isEmpty: false), Slot(id: 1, isEmpty: false)]
        #expect(TVMultiViewFocusRules.initial(slots: slots, audibleTileID: 1) == .tile(1))
    }

    @Test func aSoundTileThatIsntShowingFallsBackToTheFirst() {
        // The one-tile arrangement shows a single slot.
        let slots = [Slot(id: 1, isEmpty: false)]
        #expect(TVMultiViewFocusRules.initial(slots: slots, audibleTileID: 3) == .tile(1))
        #expect(TVMultiViewFocusRules.initial(slots: [], audibleTileID: nil) == .tile(0))
    }

    @Test func afterPickingFocusMovesOnToTheNextEmptyTile() {
        let slots = [Slot(id: 0, isEmpty: false), Slot(id: 1, isEmpty: true), Slot(id: 2, isEmpty: true)]
        #expect(TVMultiViewFocusRules.afterPicking(tile: 0, slots: slots, hasRoomForAnother: true) == .tile(1))
    }

    @Test func afterPickingItLooksPastTheTileBeforeComingRound() {
        let slots = [Slot(id: 0, isEmpty: true), Slot(id: 1, isEmpty: false), Slot(id: 2, isEmpty: true)]
        #expect(TVMultiViewFocusRules.afterPicking(tile: 1, slots: slots, hasRoomForAnother: true) == .tile(2))
        let wrap = [Slot(id: 0, isEmpty: true), Slot(id: 1, isEmpty: false), Slot(id: 2, isEmpty: false)]
        #expect(TVMultiViewFocusRules.afterPicking(tile: 2, slots: wrap, hasRoomForAnother: true) == .tile(0))
    }

    @Test func afterPickingItStaysWhenThereIsNothingLeftToFill() {
        let full = [Slot(id: 0, isEmpty: false), Slot(id: 1, isEmpty: false)]
        #expect(TVMultiViewFocusRules.afterPicking(tile: 1, slots: full, hasRoomForAnother: true) == .tile(1))
    }

    @Test func afterPickingItStaysWhenEverySourceIsFull() {
        // The empty tiles only say why they can't take a channel.
        let slots = [Slot(id: 0, isEmpty: false), Slot(id: 1, isEmpty: true)]
        #expect(TVMultiViewFocusRules.afterPicking(tile: 0, slots: slots, hasRoomForAnother: false) == .tile(0))
    }

}

@Suite struct TVMultiViewBackTests {
    @Test func menuLeavesThePickerFirst() {
        #expect(TVMultiViewBack.onMenu(hasPicker: true, hasFullScreen: false, hasPlayingTiles: true) == .closePicker)
        #expect(TVMultiViewBack.onMenu(hasPicker: true, hasFullScreen: true, hasPlayingTiles: true) == .closePicker)
    }

    @Test func thenTheFullScreenTile() {
        #expect(TVMultiViewBack.onMenu(hasPicker: false, hasFullScreen: true, hasPlayingTiles: true) == .closeFullScreen)
    }

    @Test func thenMultiViewItselfAskingWhileChannelsPlay() {
        #expect(TVMultiViewBack.onMenu(hasPicker: false, hasFullScreen: false, hasPlayingTiles: true) == .confirmLeaving)
    }

    @Test func nothingPlayingLeavesWithoutAsking() {
        #expect(TVMultiViewBack.onMenu(hasPicker: false, hasFullScreen: false, hasPlayingTiles: false) == .leave)
    }
}

@Suite struct MultiViewChannelAvailabilityTests {
    private func state(inUse: Int, limit: Int?) -> SourceStreamState {
        SourceStreamState(sourceID: Fixture.sourceA, name: "Provider A", inUse: inUse, limit: limit)
    }

    @Test func aChannelWithRoomCanBePicked() {
        #expect(MultiViewChannelAvailability.of(isOnScreen: false, source: state(inUse: 1, limit: 2)) == .available)
        #expect(MultiViewChannelAvailability.of(isOnScreen: false, source: state(inUse: 9, limit: nil)) == .available)
        #expect(MultiViewChannelAvailability.of(isOnScreen: false, source: nil) == .available)
        #expect(MultiViewChannelAvailability.available.note == nil)
    }

    @Test func aFullSourceSaysHowFull() {
        let availability = MultiViewChannelAvailability.of(isOnScreen: false, source: state(inUse: 2, limit: 2))
        #expect(availability == .sourceFull("Provider A is at its limit (2 of 2)"))
        #expect(availability.note == "Provider A is at its limit (2 of 2)")
    }

    @Test func aChannelOnScreenSaysThatBeforeAnythingAboutItsSource() {
        let availability = MultiViewChannelAvailability.of(isOnScreen: true, source: state(inUse: 2, limit: 2))
        #expect(availability == .onScreen)
        #expect(availability.note == "On screen")
    }
}

@Suite struct MultiViewStartTests {
    @Test func theChannelTakesATileWhileItsSourceHasRoom() {
        let states = [SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 1, limit: 2)]
        #expect(MultiViewStart.canPlay(sourceID: Fixture.sourceA, states: states))
    }

    @Test func notWhenItsSourceIsFull() {
        let states = [SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 1, limit: 1)]
        #expect(!MultiViewStart.canPlay(sourceID: Fixture.sourceA, states: states))
    }

    @Test func anotherSourceBeingFullDoesntMatter() {
        let states = [
            SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 1, limit: 1),
            SourceStreamState(sourceID: Fixture.sourceB, name: "B", inUse: 0, limit: 1),
        ]
        #expect(MultiViewStart.canPlay(sourceID: Fixture.sourceB, states: states))
    }

    @Test func aSourceWithNoLimitOrNoStateHasRoom() {
        let states = [SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 40, limit: nil)]
        #expect(MultiViewStart.canPlay(sourceID: Fixture.sourceA, states: states))
        #expect(MultiViewStart.canPlay(sourceID: Fixture.sourceB, states: []))
    }
}

@Suite struct MultiViewResumeTests {
    private func saved(_ id: Int, _ source: UUID = Fixture.sourceA) -> MultiViewResume.Saved {
        MultiViewResume.Saved(tileID: id, sourceID: source)
    }

    @Test func everyTileReopensWhenThereIsRoom() {
        let states = [SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 0, limit: 4)]
        #expect(MultiViewResume.tilesToReopen([saved(0), saved(1), saved(2)], states: states) == [0, 1, 2])
    }

    @Test func aSourceWithNoLimitOrNoStateTakesThemAll() {
        let states = [SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 9, limit: nil)]
        #expect(MultiViewResume.tilesToReopen([saved(0), saved(1)], states: states) == [0, 1])
        #expect(MultiViewResume.tilesToReopen([saved(0), saved(1)], states: []) == [0, 1])
    }

    @Test func eachReopenedTileCountsAgainstItsSource() {
        // Someone else took one of the two streams while the app was away.
        let states = [SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 1, limit: 2)]
        #expect(MultiViewResume.tilesToReopen([saved(0), saved(1)], states: states) == [0])
    }

    @Test func aFullSourceReopensNothing() {
        let states = [SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 1, limit: 1)]
        #expect(MultiViewResume.tilesToReopen([saved(0)], states: states).isEmpty)
    }

    @Test func oneSourceBeingFullDoesntStopAnother() {
        let states = [
            SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 1, limit: 1),
            SourceStreamState(sourceID: Fixture.sourceB, name: "B", inUse: 0, limit: 1),
        ]
        #expect(MultiViewResume.tilesToReopen([saved(0), saved(1, Fixture.sourceB)], states: states) == [1])
    }

    @Test func slotsGoInOrderWhateverOrderTheyWereSavedIn() {
        let states = [SourceStreamState(sourceID: Fixture.sourceA, name: "A", inUse: 0, limit: 1)]
        #expect(MultiViewResume.tilesToReopen([saved(3), saved(0)], states: states) == [0])
    }
}

@Suite struct TVChannelPickerFocusTests {
    @Test func opensOnTheFirstChannelThatCanBeChosen() {
        #expect(TVChannelPickerFocus.initial(channelKeys: ["a", "b"], firstAvailableKey: "b") == .channel("b"))
    }

    @Test func withEveryChannelBlockedItStillFocusesTheList() {
        #expect(TVChannelPickerFocus.initial(channelKeys: ["a", "b"], firstAvailableKey: nil) == .channel("a"))
    }

    @Test func withNoChannelsTheSearchFieldHoldsFocusSoMenuStillWorks() {
        #expect(TVChannelPickerFocus.initial(channelKeys: [], firstAvailableKey: nil) == .search)
    }

    @Test func theSearchFieldIsAlwaysThere() {
        #expect(TVChannelPickerFocus.search.isValid(channelKeys: [], chipIDs: [], isSearching: false))
        #expect(TVChannelPickerFocus.search.isValid(channelKeys: [], chipIDs: [], isSearching: true))
    }

    @Test func aChannelMustStillBeListed() {
        #expect(TVChannelPickerFocus.channel("a").isValid(channelKeys: ["a"], chipIDs: [], isSearching: false))
        #expect(!TVChannelPickerFocus.channel("a").isValid(channelKeys: ["b"], chipIDs: [], isSearching: false))
    }

    @Test func theChipsGoWhileSearchingAndClearOnlyShowsThen() {
        #expect(TVChannelPickerFocus.chip("all").isValid(channelKeys: [], chipIDs: ["all"], isSearching: false))
        #expect(!TVChannelPickerFocus.chip("all").isValid(channelKeys: [], chipIDs: ["all"], isSearching: true))
        #expect(!TVChannelPickerFocus.chip("gone").isValid(channelKeys: [], chipIDs: ["all"], isSearching: false))
        #expect(TVChannelPickerFocus.clearSearch.isValid(channelKeys: [], chipIDs: [], isSearching: true))
        #expect(!TVChannelPickerFocus.clearSearch.isValid(channelKeys: [], chipIDs: [], isSearching: false))
    }
}

@Suite struct MultiViewGridRowsTests {
    @Test func tilesFillRowsInReadingOrder() {
        #expect(MultiViewGridGeometry.rows(of: [0, 1, 2, 3], columns: 2) == [[0, 1], [2, 3]])
        #expect(MultiViewGridGeometry.rows(of: [0, 1, 2], columns: 2) == [[0, 1], [2]])
        #expect(MultiViewGridGeometry.rows(of: [0, 1, 2], columns: 3) == [[0, 1, 2]])
        #expect(MultiViewGridGeometry.rows(of: [0], columns: 1) == [[0]])
    }

    @Test func noTilesMakeNoRows() {
        #expect(MultiViewGridGeometry.rows(of: [Int](), columns: 2).isEmpty)
    }

    @Test func aNonsenseColumnCountStillMakesRows() {
        #expect(MultiViewGridGeometry.rows(of: [0, 1], columns: 0) == [[0], [1]])
    }
}
