import XCTest

/// A scripted Siri Remote for the app already running on the Apple TV
/// simulator. `STEPS` is a comma list: up, down, left, right, select, menu,
/// playpause, wait (1 s), shot. After each it prints what holds focus; with
/// `OUT` set it saves a screenshot per step there. It stops when the app
/// leaves the foreground, so later presses can't land on the TV's own home
/// screen and open something else.
final class Remote: XCTestCase {
    func testDrive() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication(bundleIdentifier: "com.bhavikjain.hearth.dev")
        app.activate()
        let steps = (environment["STEPS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let out = environment["OUT"].map { URL(fileURLWithPath: $0) }
        let remote = XCUIRemote.shared

        print("STEP 0 start | focus \(app.focusDescription)")
        for (index, step) in steps.enumerated() {
            switch step {
            case "up": remote.press(.up)
            case "down": remote.press(.down)
            case "left": remote.press(.left)
            case "right": remote.press(.right)
            case "select": remote.press(.select)
            case "menu": remote.press(.menu)
            case "playpause": remote.press(.playPause)
            case "wait": Thread.sleep(forTimeInterval: 1)
            case "shot": break
            default: XCTFail("Unknown step: \(step)")
            }
            Thread.sleep(forTimeInterval: 0.8)
            guard app.state == .runningForeground else {
                print("STEP \(index + 1) \(step) | the app left the foreground; stopping")
                break
            }
            print("STEP \(index + 1) \(step) | focus \(app.focusDescription)")
            if let out, step != "wait" {
                let name = String(format: "%02d-%@.png", index + 1, step)
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent(name))
            }
        }
    }
}

extension XCUIApplication {
    /// The element holding focus.
    var focusedElement: XCUIElement {
        descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    /// Its label (or identifier), for a log. From a snapshot, which throws
    /// when the query can't be answered: `exists` fails the test instead, which
    /// it did once after 140 s on a Mac busy with other builds.
    var focusDescription: String {
        guard let element = try? focusedElement.snapshot() else { return "(nothing)" }
        return element.label.isEmpty ? element.identifier : element.label
    }
}
