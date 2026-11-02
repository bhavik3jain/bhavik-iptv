import XCTest

/// What a unit test can't see on the Apple TV: where the remote goes. Each
/// flow launches the demo (`-StubProvider`, in-memory stores) and presses real
/// remote buttons. Every one of these was broken once; see the 2026-10-28
/// entry in docs/TRACKING.md.
final class TVFlows: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.bhavikjain.hearth.dev")
        app.launchArguments = ["-StubProvider", "YES", "-InMemoryStores", "YES", "-SelectProfile", "Bhavik"]
        app.launch()
        expectFocus("Home")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: Where focus lands

    func testDownFromTheHomeTabLandsOnResume() throws {
        press(.down)
        expectFocus("Resume")
    }

    func testDownFromTheLiveTVTabLandsOnWhatIsOnNow() throws {
        press(.right)
        expectFocus("Live TV")
        press(.down)
        expectFocus("On now")
    }

    // MARK: Menu goes back

    func testMenuLeavesAShowsPage() throws {
        press(.down)
        expectFocus("Resume")
        press(.right)
        expectFocus("Go to show")
        press(.select)
        expectFocus("Season")
        press(.menu)
        expectFocus("Go to show")
    }

    /// It used to quit the app: the gate had nowhere to go back to.
    func testMenuOnTheGateAfterSwitchProfileGoesBack() throws {
        openGateFromSettings()
        press(.menu)
        XCTAssertTrue(waitForGate(toBeShowing: false), "Menu should leave the gate")
        XCTAssertEqual(app.state, .runningForeground, "Menu should not quit the app")
    }

    /// The guide's cells say "On now"; the player's picture only has the
    /// programme's title. So this tells the guide from a player still up, as
    /// the guide's buttons can't: they stay in the tree under the player.
    func testOneMenuClosesThePlayerAfterAChannelChange() throws {
        openPlayerFromTheGuide()
        press(.up)
        press(.menu)
        expectFocus("On now", timeout: 5)
    }

    /// With the controls in focus, Menu goes back to the picture first, and a
    /// second press closes the player (`TVPlayerScreen`).
    func testMenuLeavesTheControlsThenThePlayer() throws {
        openPlayerFromTheGuide()
        press(.select)
        press(.menu)
        XCTAssertFalse(app.focusDescription.contains("On now"), "The first Menu should stay in the player")
        press(.menu)
        expectFocus("On now", timeout: 5)
    }

    // MARK: Multi-view

    /// Back used to stop every channel without a word. Focus starts on keeping
    /// them playing, and back again dismisses the warning, so pressing back
    /// twice stops nothing.
    func testMenuInMultiViewWarnsBeforeStopping() throws {
        openMultiView()
        press(.select) // Add a channel
        expectFocus("Cityline News")
        press(.select) // the first channel
        expectFocus("Add a channel")

        press(.menu)
        expectFocus("Keep Playing in Background")
        press(.menu) // back again dismisses the warning, and nothing stops
        expectFocus("Add a channel")
        XCTAssertEqual(app.state, .runningForeground)

        press(.menu)
        expectFocus("Keep Playing in Background")
        moveFocus(to: "Stop Multi-view")
        press(.select)
        expectFocus("Multi-view") // back on the guide's pill
    }

    /// Keeps the tiles playing, shows the way back beside the tab bar, and
    /// returns to them as they were.
    func testMultiViewKeepsPlayingInTheBackgroundAndComesBack() throws {
        openMultiView()
        press(.select) // Add a channel
        expectFocus("Cityline News")
        press(.select) // the first channel
        expectFocus("Add a channel")

        press(.menu)
        expectFocus("Keep Playing in Background")
        press(.select)
        expectFocus("Multi-view") // back on the guide

        openBackgroundReturn(named: "Cityline News")
        XCTAssertTrue(app.staticTexts["Multi-view"].waitForExistence(timeout: 5), "Should be back in multi-view")
        expectFocus("Cityline News") // the tile, still playing

        // And stopping for real leaves nothing behind.
        press(.menu)
        expectFocus("Keep Playing in Background")
        moveFocus(to: "Stop Multi-view")
        press(.select)
        // Back where the way back was pressed: Settings, the last tab.
        expectFocus("Switch profile")
        XCTAssertFalse(app.buttons["Return to Cityline News"].exists)
    }

    /// The player's own button: off screen with the stream going, and back.
    func testThePlayerKeepsPlayingInTheBackgroundAndComesBack() throws {
        openPlayerFromTheGuide()
        press(.select) // the controls
        press(.up)
        moveFocus(to: "Keep playing in the background")
        press(.select)
        expectFocus("On now", timeout: 5)

        let title = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Return to '")).firstMatch.label as String?)
        openBackgroundReturn(named: String(title.dropFirst("Return to ".count)))
        XCTAssertFalse(app.focusDescription.contains("On now"), "Should be back in the player")
    }

    func testMenuInAnEmptyMultiViewLeavesWithoutAsking() throws {
        openMultiView()
        expectFocus("Add a channel")
        press(.menu)
        expectFocus("Multi-view")
    }

    // MARK: Household

    /// It used to open as a narrow card, with controls the TV can't honor.
    func testHouseholdFromTheGateFillsTheScreenAndIsReadOnly() throws {
        openGateFromSettings()
        press(.down)
        expectFocus("Household")
        press(.select)

        let notice = app.staticTexts["Manage the household from your iPhone, iPad or Mac"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        // A narrow card sat in the middle of the screen, a third of the way in.
        let width = app.windows.firstMatch.frame.width
        XCTAssertLessThan(notice.frame.minX, width * 0.25, "The page starts \(notice.frame.minX) in on a \(width) screen")

        for control in ["Invite someone", "Rename household", "Add profile", "Add a portal, Xtream login or playlist", "Mark adult categories"] {
            XCTAssertFalse(app.buttons[control].exists, "\(control) shouldn't be on the TV")
        }

        press(.menu)
        XCTAssertTrue(waitForGate(toBeShowing: true), "Menu should go back to the gate")
    }

    // MARK: Layout

    /// The backdrop sits behind the scroll view, which used to be only as
    /// wide as a movie's text, leaving grey bars down both sides.
    func testAMoviesPageSpansTheScreen() throws {
        press(.right, times: 2)
        expectFocus("Movies")
        press(.down, times: 2)
        press(.select)
        expectFocus("Play")
        let page = app.scrollViews.containing(.button, identifier: "Play").firstMatch
        XCTAssertTrue(page.exists)
        let width = app.windows.firstMatch.frame.width
        XCTAssertGreaterThan(page.frame.width, width * 0.85, "The page is \(page.frame.width) wide on a \(width) screen")
    }

    // MARK: Getting around

    private func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    private func openGateFromSettings() {
        press(.right, times: 5)
        expectFocus("Settings")
        press(.down)
        expectFocus("Switch profile")
        press(.select)
        XCTAssertTrue(waitForGate(toBeShowing: true), "Switch profile should open the gate")
    }

    /// Up to the tab bar, right past the last tab, and Select.
    private func openBackgroundReturn(named name: String) {
        XCTAssertTrue(app.buttons["Return to \(name)"].waitForExistence(timeout: 5), "The way back should show")
        var presses = 0
        while !app.focusDescription.contains("Return to"), presses < 14 {
            let onTabBar = ["Search", "Home", "Live TV", "Movies", "Shows", "My List", "Settings"].contains(app.focusDescription)
            press(onTabBar ? .right : .up)
            presses += 1
        }
        expectFocus("Return to \(name)")
        press(.select)
    }

    /// Walks a row or column of buttons, any way, until one has focus.
    private func moveFocus(to label: String) {
        for direction in [XCUIRemote.Button.down, .right, .up, .left] {
            for _ in 0..<3 where !app.focusDescription.contains(label) {
                press(direction)
            }
        }
        expectFocus(label)
    }

    private func openMultiView() {
        press(.right)
        expectFocus("Live TV")
        press(.down)
        expectFocus("On now")
        press(.up, times: 2)
        expectFocus("Multi-view")
        press(.select)
        expectFocus("Add a channel")
    }

    /// Plays what's on now on the first channel, with the controls faded.
    private func openPlayerFromTheGuide() {
        press(.right)
        expectFocus("Live TV")
        press(.down)
        expectFocus("On now")
        press(.select)
        Thread.sleep(forTimeInterval: 6)
    }

    private func waitForGate(toBeShowing showing: Bool, timeout: TimeInterval = 5) -> Bool {
        let title = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'watching?'")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if title.exists == showing { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// `continueAfterFailure` is off, so a failure here ends the flow.
    private func expectFocus(_ text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.focusDescription.contains(text) { return }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        XCTFail("Expected focus on \"\(text)\", found \"\(app.focusDescription)\"", file: file, line: line)
    }
}
