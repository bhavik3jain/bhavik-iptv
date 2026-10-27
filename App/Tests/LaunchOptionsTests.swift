import Foundation
import Testing
@testable import Hearth

// The Debug launch arguments (CLAUDE.md), parsed the same in every build.

@Suite struct LaunchOptionsTests {
    @Test func noArgumentsMeansNothingAsked() {
        #expect(LaunchOptions(arguments: []) == .empty)
        // What Xcode itself passes is ignored.
        #expect(LaunchOptions(arguments: ["-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES"]) == .empty)
    }

    @Test func everyOptionAtOnce() {
        let options = LaunchOptions(arguments: [
            "-InMemoryStores", "YES",
            "-StubProvider", "YES",
            "-SeedPIN", "1234",
            "-SelectProfile", "Anya",
            "-OpenTab", "live",
            "-OpenRoute", "series:first",
            "-AutoPlay", "first-channel",
            "-SourceProbe", "Provider B",
            "-InitializeCloudKitSchema", "YES",
        ])
        #expect(options.inMemoryStores)
        #expect(options.stubProvider)
        #expect(options.seedPIN == "1234")
        #expect(options.selectProfile == "Anya")
        #expect(options.openTab == .live)
        #expect(options.openRoute == LaunchOptions.Route("series:first"))
        #expect(options.autoPlay == .firstChannel)
        #expect(options.sourceProbe == "Provider B")
        #expect(options.initializeCloudKitSchema)
    }

    // MARK: Flags

    @Test(arguments: ["YES", "yes", "true", "TRUE", "1"])
    func flagsAcceptYesTrueAndOne(value: String) {
        #expect(LaunchOptions(arguments: ["-InMemoryStores", value]).inMemoryStores)
        #expect(LaunchOptions(arguments: ["-StubProvider", value]).stubProvider)
        #expect(LaunchOptions(arguments: ["-InitializeCloudKitSchema", value]).initializeCloudKitSchema)
    }

    @Test(arguments: ["NO", "false", "0", "on", ""])
    func anythingElseLeavesAFlagOff(value: String) {
        #expect(!LaunchOptions(arguments: ["-InMemoryStores", value]).inMemoryStores)
    }

    /// A key followed by another key has no value and is ignored; the next
    /// key still reads its own value.
    @Test func aKeyWithoutAValueIsIgnored() {
        let options = LaunchOptions(arguments: ["-InMemoryStores", "-StubProvider", "YES", "-SelectProfile"])
        #expect(!options.inMemoryStores)
        #expect(options.stubProvider)
        #expect(options.selectProfile == nil)
    }

    /// "-5" is a value, not a key: only "-" and a letter starts a key.
    @Test func aNegativeNumberIsAValue() {
        #expect(LaunchOptions(arguments: ["-SelectProfile", "-5"]).selectProfile == "-5")
    }

    @Test func theLastValueOfARepeatedKeyWins() {
        #expect(LaunchOptions(arguments: ["-OpenTab", "live", "-OpenTab", "movies"]).openTab == .movies)
    }

    @Test func strayValuesAreSkipped() {
        let options = LaunchOptions(arguments: ["stray", "-", "YES", "-StubProvider", "YES"])
        #expect(options.stubProvider)
        #expect(!options.inMemoryStores)
    }

    // MARK: Values

    @Test func seedPINMustBeFourASCIIDigits() {
        #expect(LaunchOptions(arguments: ["-SeedPIN", "0007"]).seedPIN == "0007")
        for bad in ["123", "12345", "12a4", "١٢٣٤", "12 4"] {
            #expect(LaunchOptions(arguments: ["-SeedPIN", bad]).seedPIN == nil, "\(bad)")
        }
    }

    @Test func profileAndProbeNamesAreTrimmedAndNeverBlank() {
        let options = LaunchOptions(arguments: ["-SelectProfile", "  Kids ", "-SourceProbe", "   "])
        #expect(options.selectProfile == "Kids")
        #expect(options.sourceProbe == nil)
    }

    @Test func openTabReadsRawValuesInAnyCase() {
        #expect(LaunchOptions(arguments: ["-OpenTab", "MyList"]).openTab == .myList)
        #expect(LaunchOptions(arguments: ["-OpenTab", "SETTINGS"]).openTab == .settings)
        #expect(LaunchOptions(arguments: ["-OpenTab", "myList2"]).openTab == nil)
        #expect(LaunchOptions(arguments: ["-OpenTab", "my-list"]).openTab == nil)
    }

    @Test func autoPlayReadsBothKindsInAnyCase() {
        #expect(LaunchOptions(arguments: ["-AutoPlay", "First-Movie"]).autoPlay == .firstMovie)
        #expect(LaunchOptions(arguments: ["-AutoPlay", "first-channel"]).autoPlay == .firstChannel)
        #expect(LaunchOptions(arguments: ["-AutoPlay", "first-show"]).autoPlay == nil)
    }

    // MARK: -OpenRoute

    @Test(arguments: [
        ("series:first", LaunchOptions.Route.Kind.series),
        ("movie:FIRST", .movie),
        ("Channel:First", .channel),
    ])
    func firstOfAKind(text: String, kind: LaunchOptions.Route.Kind) throws {
        let route = try #require(LaunchOptions.Route(text))
        #expect(route.kind == kind)
        #expect(route.target == .first)
    }

    /// Splits at the first colon only, and keeps the key's case: item keys
    /// hold colons (a Stalker id) and are case-sensitive.
    @Test func anItemKeySplitsAtTheFirstColonOnly() throws {
        let key = "5A1E5A1E-0000-4000-8000-000000000001/channel/ch:101"
        let route = try #require(LaunchOptions.Route("channel:\(key)"))
        #expect(route.kind == .channel)
        #expect(route.target == .itemKey(key))
    }

    @Test(arguments: ["channel:", "podcast:first", "first", "", ":first"])
    func malformedRoutesAreIgnored(text: String) {
        #expect(LaunchOptions.Route(text) == nil)
        #expect(LaunchOptions(arguments: ["-OpenRoute", text]).openRoute == nil)
    }

    // MARK: The test host

    @Test func theTestHostIsDetectedFromXcodesEnvironment() {
        #expect(LaunchOptions.isHostingTests(environment: ["XCTestConfigurationFilePath": "/x.xctestconfiguration"]))
        #expect(LaunchOptions.isHostingTests(environment: ["XCTestBundlePath": "/HearthTests.xctest"]))
        #expect(LaunchOptions.isHostingTests(environment: ["XCTestSessionIdentifier": "1"]))
        #expect(!LaunchOptions.isHostingTests(environment: ["HOME": "/Users/test"]))
        #expect(!LaunchOptions.isHostingTests(environment: [:]))
    }

    /// This very run: the app hosting these tests opened in-memory stores.
    @Test func thisRunsHostOpensInMemoryStores() {
        #expect(LaunchOptions.isHostingTests(environment: ProcessInfo.processInfo.environment))
        #expect(LaunchOptions.current.inMemoryStores)
    }
}
