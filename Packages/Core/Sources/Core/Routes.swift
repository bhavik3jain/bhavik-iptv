import SwiftUI

/// Where a feature can send the user without importing the feature that owns
/// the screen. Features push these with `NavigationLink(value:)`; the app's
/// composition root maps each case to a view with
/// `.navigationDestination(for: HearthRoute.self)`.
///
/// Item keys are CatalogKit's `ItemKey.rawValue` strings, so Core stays free of
/// every other package.
public enum HearthRoute: Hashable, Sendable {
    case movie(itemKey: String)
    case series(itemKey: String)
    /// A channel's page: its guide for today and the days the guide holds.
    case channel(itemKey: String)
    case liveGuide
    case search(query: String)
    case household
    case profileEditor(profileID: UUID?)
    case sourceEditor(sourceID: UUID?)
    case settings
}

/// A request to play something, made by any feature and carried out by the
/// app's playback coordinator: it resolves a fresh stream link through the
/// catalog, checks the source's stream limit, opens the player and records
/// progress for the current profile.
public struct PlayIntent: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// A live channel, now.
        case live
        /// An aired programme on a channel with an archive (LIV-4), or a live
        /// programme from its start ("From the start").
        case catchup
        case movie
        case episode
    }

    public var id: String { itemKey + (catchupStart.map { "@\($0.timeIntervalSince1970)" } ?? "") }

    /// CatalogKit `ItemKey.rawValue` of the channel, movie or episode.
    public var itemKey: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var artworkURL: URL?
    /// Resume point for movies and episodes, in seconds. Nil starts at the
    /// beginning (or at the profile's saved progress, if the coordinator finds
    /// one).
    public var startPosition: TimeInterval?
    /// For `.catchup`: the programme's start and end.
    public var catchupStart: Date?
    public var catchupEnd: Date?
    /// For `.live`: the channel keys channel up and down walk through, in
    /// order (usually the category the user was looking at). For `.episode`:
    /// the episode keys that follow, for up next.
    public var queue: [String]

    public init(
        itemKey: String,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        startPosition: TimeInterval? = nil,
        catchupStart: Date? = nil,
        catchupEnd: Date? = nil,
        queue: [String] = []
    ) {
        self.itemKey = itemKey
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.startPosition = startPosition
        self.catchupStart = catchupStart
        self.catchupEnd = catchupEnd
        self.queue = queue
    }
}

/// `@Environment(\.play)` — call it with a `PlayIntent`. The default does
/// nothing, so previews and tests never need a player.
public struct PlayAction: Sendable {
    private let handler: @MainActor @Sendable (PlayIntent) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (PlayIntent) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ intent: PlayIntent) {
        handler(intent)
    }
}

/// `@Environment(\.openRoute)` — for places a `NavigationLink(value:)` can't
/// reach (a button inside a sheet, a context menu, the Mac sidebar).
public struct OpenRouteAction: Sendable {
    private let handler: @MainActor @Sendable (HearthRoute) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (HearthRoute) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ route: HearthRoute) {
        handler(route)
    }
}

/// How the app is laid out right now. Features ask this — never the platform,
/// the idiom or the orientation — to decide between the phone layout and the
/// sidebar layout. `.sidebar` is the Mac, an iPad, and iPhone Duo's inner
/// display: anywhere the horizontal size class is regular. `.tv` is the
/// Apple TV: a 10-foot screen driven by focus and the Siri Remote, where the
/// features draw their own variants (large cards, rows the focus engine can
/// walk) rather than the phone or sidebar layout.
public enum HearthLayout: Sendable {
    case compact
    case sidebar
    case tv

    /// The wide layouts: what a feature built for `.sidebar` also shows on a
    /// TV screen it hasn't got a TV variant for.
    public var isWide: Bool { self != .compact }
}

extension EnvironmentValues {
    @Entry public var play = PlayAction { _ in }
    @Entry public var openRoute = OpenRouteAction { _ in }
    @Entry public var hearthLayout: HearthLayout = .compact
}
