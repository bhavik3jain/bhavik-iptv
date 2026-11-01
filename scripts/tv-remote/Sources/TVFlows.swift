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
