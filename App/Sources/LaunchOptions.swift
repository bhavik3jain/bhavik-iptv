import Foundation

/// The places the app's top level can show: the phone's tabs, the iPad and
/// iPhone Duo sidebar's extra rows, and the Mac sidebar.
enum AppTab: String, Hashable, CaseIterable, Sendable {
    case home
    case live
    case movies
    case shows
    case myList = "mylist"
    case downloads
    case search
    case household
    case settings

    /// The five tabs of the phone's tab bar (mockup 02).
    static let primary: [AppTab] = [.home, .live, .movies, .shows, .myList]
    /// The Mac sidebar's sections, in ⌘1–⌘6 order (mockup 07).
    static let macSections: [AppTab] = [.home, .live, .movies, .shows, .myList, .downloads]
    /// The Apple TV's top tab bar: Search at the leading end, where tvOS
    /// apps keep it; no Downloads; Household inside Settings.
    static let tv: [AppTab] = [.search, .home, .live, .movies, .shows, .myList, .settings]

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .live: String(localized: "Live TV")
        case .movies: String(localized: "Movies")
        case .shows: String(localized: "Shows")
        case .myList: String(localized: "My List")
        case .downloads: String(localized: "Downloads")
        case .search: String(localized: "Search")
        case .household: String(localized: "Household")
        case .settings: String(localized: "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .live: "tv"
        case .movies: "film"
        case .shows: "rectangle.stack"
        case .myList: "heart"
        case .downloads: "arrow.down.circle"
        case .search: "magnifyingglass"
        case .household: "person.2"
        case .settings: "gearshape"
        }
    }
}

/// The launch arguments the verification step and the owner drive the app
/// with (CLAUDE.md, Debug launch arguments). Parsed in every build so the
/// parsing can be tested; acted on only in Debug (`LaunchOptions.current`).
struct LaunchOptions: Equatable, Sendable {
    /// `-AutoPlay first-channel|first-movie`.
    enum AutoPlay: String, Equatable, Sendable {
        case firstChannel = "first-channel"
        case firstMovie = "first-movie"
    }

    /// `-OpenRoute series|movie|channel:first|<itemKeyRaw>`.
    struct Route: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable { case series, movie, channel }
        enum Target: Equatable, Sendable {
            /// The first item of that kind once the catalog has loaded.
            case first
            case itemKey(String)
        }

        var kind: Kind
        var target: Target

        /// Splits at the first colon only: an item key can hold one.
        init?(_ text: String) {
            guard let colon = text.firstIndex(of: ":"),
                  let kind = Kind(rawValue: String(text[..<colon]).lowercased()) else { return nil }
            let rest = String(text[text.index(after: colon)...])
            guard !rest.isEmpty else { return nil }
            self.kind = kind
            self.target = rest.lowercased() == "first" ? .first : .itemKey(rest)
        }
    }

    /// `-InMemoryStores YES`: no iCloud, nothing on disk.
    var inMemoryStores = false
    /// `-StubProvider YES`: the demo provider and the mockup's profiles.
    var stubProvider = false
    /// `-SeedPIN 1234`: the seeded owner profile gets this PIN.
    var seedPIN: String?
    /// `-SelectProfile Anya`: skip the gate.
    var selectProfile: String?
    /// `-OpenTab live`.
    var openTab: AppTab?
    var openRoute: Route?
    var autoPlay: AutoPlay?
    /// `-SourceProbe "Provider B"`: sign in to that household source and
    /// print each step.
    var sourceProbe: String?
    /// `-InitializeCloudKitSchema YES`.
    var initializeCloudKitSchema = false

    static let empty = LaunchOptions()

    /// Reads `-Key value` pairs; a key without a value is ignored.
    init(arguments: [String]) {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let next = arguments.index(after: index)
            if argument.hasPrefix("-"), argument.count > 1, next < arguments.endIndex, !Self.isKey(arguments[next]) {
                values[String(argument.dropFirst())] = arguments[next]
                index = arguments.index(after: next)
            } else {
                index = next
            }
        }
        inMemoryStores = Self.flag(values["InMemoryStores"])
        stubProvider = Self.flag(values["StubProvider"])
        if let pin = values["SeedPIN"], pin.count == 4, pin.allSatisfy(\.isASCIIDigit) { seedPIN = pin }
        selectProfile = values["SelectProfile"].flatMap(Self.nonEmpty)
        openTab = values["OpenTab"].flatMap { AppTab(rawValue: $0.lowercased()) }
        openRoute = values["OpenRoute"].flatMap(Route.init)
        autoPlay = values["AutoPlay"].flatMap { AutoPlay(rawValue: $0.lowercased()) }
        sourceProbe = values["SourceProbe"].flatMap(Self.nonEmpty)
        initializeCloudKitSchema = Self.flag(values["InitializeCloudKitSchema"])
    }

    private init() {}

    /// This launch's options: parsed from the process in Debug, none in Release.
    static let current: LaunchOptions = {
        #if DEBUG
        LaunchOptions(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst()))
        #else
        .empty
        #endif
    }()

    /// A value never starts with "-" followed by a letter ("-5" is a value).
    private static func isKey(_ text: String) -> Bool {
        guard text.hasPrefix("-"), let second = text.dropFirst().first else { return false }
        return second.isLetter
    }

    private static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["yes", "true", "1"].contains(value.lowercased())
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
