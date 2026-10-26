#if DEBUG
import CatalogKit
import Core
import Foundation
import HouseholdKit
import SourceKit

/// What the Debug launch arguments do (CLAUDE.md, Debug launch arguments):
/// the demo household, skipping the gate, opening a tab, a detail screen or
/// the player once the catalog has loaded, the source probe and the schema
/// ritual. These are how the verification step drives screenshots, so each
/// one waits for what it needs (the catalog's first import) rather than
/// failing on a cold start. None of it exists in Release.
@MainActor
enum DebugLaunch {
    /// The mockups' household: "Jain Household" with Bhavik, Anya, Kids and
    /// Guest (mockup 01). The names are the mockups' placeholders.
    static let demoHouseholdName = "Jain Household"

    /// How long a launch argument waits for the catalog's first import (the
    /// demo provider takes a second or two; a real portal much longer).
    static let catalogWait: Duration = .seconds(120)

    static func run(model: AppModel, services: AppServices) async {
        let launch = model.launch
        let seeded = launch.stubProvider ? seedDemoHousehold(services, pin: launch.seedPIN) : false
        if let name = launch.selectProfile {
            selectProfile(named: name, session: services.session, store: services.store)
        }
        if let name = launch.sourceProbe {
            runSourceProbe(named: name, store: services.store)
        }
        // The rest needs the catalog, which imports in the background.
        Task {
            if seeded { await finishDemoSeed(services) }
            if let route = launch.openRoute {
                await openRoute(route, model: model, catalog: services.catalog)
            }
            if let autoPlay = launch.autoPlay {
                await self.autoPlay(autoPlay, services: services)
            }
        }
    }

    // MARK: -StubProvider YES

    /// Adds the demo provider and the mockup's profiles to a household with
    /// no sources. Returns whether it did (favorites, progress and the Kids
    /// categories follow once the catalog has loaded).
    private static func seedDemoHousehold(_ services: AppServices, pin: String?) -> Bool {
        let store = services.store
        guard store.sources.allSatisfy(\.isRemoved) else { return false }
        _ = store.addSource(SourceRecord(
            id: SourceConfiguration.stub().id,
            name: "Demo Provider",
            kindRaw: SourceKind.stalker.rawValue,
            serverURL: StubSourceClient.serverURL,
            maxStreams: 2
        ))
        store.renameHousehold(demoHouseholdName)

        // The first profile (made with the household) becomes Bhavik.
        if var first = store.profiles.first(where: { $0.kind == .standard }) {
            first.name = "Bhavik"
            first.avatarColor = .amber
            store.updateProfile(first)
            if let pin {
                store.setPIN(pin, for: first.id)
            }
        }
        let existing = Set(store.profiles.map { $0.name.lowercased() })
        if !existing.contains("anya") {
            _ = store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal)
        }
        if !existing.contains("kids") {
            _ = store.addProfile(name: "Kids", kind: .kids, avatarColor: .lavender, avatarSymbol: "face.smiling")
        }
        if !existing.contains("guest") {
            _ = store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate)
        }
        print("[DebugLaunch] Seeded the demo household")
        return true
    }

    /// Once the demo catalog is in: the Kids profile's categories, a few
    /// favorite channels and some progress, so Home has content (mockup 02).
    private static func finishDemoSeed(_ services: AppServices) async {
        let catalog = services.catalog
        let store = services.store
        guard await waitFor({ !catalog.channels(applyingFilter: false).isEmpty }) else { return }

        if var kids = store.profiles.first(where: { $0.kind == .kids }) {
            kids.allowedCategoryKeys = DemoSeed.kidsCategoryIDs(
                ContentKind.allCases.flatMap { catalog.categories(kind: $0, applyingFilter: false) }
            )
            store.updateProfile(kids)
        }
        guard let owner = store.profiles.first(where: { $0.name == "Bhavik" }) else { return }

        let channels = catalog.channels(applyingFilter: false)
        for channel in DemoSeed.favoriteChannels(channels) where !store.isFavorite(profileID: owner.id, itemKey: channel.key.rawValue) {
            store.toggleFavorite(profileID: owner.id, itemKey: channel.key.rawValue, kind: .channel)
        }
        let movies = catalog.movies(limit: 12)
        for (index, movie) in movies.prefix(2).enumerated() {
            let duration = movie.duration ?? 6000
            store.saveProgress(profileID: owner.id, itemKey: movie.key.rawValue, kind: .movie,
                               position: duration * (index == 0 ? 0.4 : 0.15), duration: duration)
        }
        if let movie = movies.dropFirst(2).first {
            store.toggleFavorite(profileID: owner.id, itemKey: movie.key.rawValue, kind: .movie)
        }
        let shows = catalog.series(limit: 3)
        for (index, show) in shows.enumerated() {
            if index == 0 { store.toggleFavorite(profileID: owner.id, itemKey: show.key.rawValue, kind: .series) }
            guard let episodes = try? await catalog.episodes(for: show), !episodes.isEmpty else { continue }
            // Salt & Signal-style: partway through an episode a little way in.
            let ordered = episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            let episode = ordered[min(index + 1, ordered.count - 1)]
            let duration = episode.duration ?? 2700
            store.saveProgress(
                profileID: owner.id, itemKey: episode.key.rawValue, kind: .episode,
                position: duration * 0.35, duration: duration,
                seriesKey: show.key.rawValue, season: episode.season, episode: episode.number
            )
        }
        print("[DebugLaunch] Seeded favorites and progress")
    }

    // MARK: -SelectProfile <name>

    private static func selectProfile(named name: String, session: ProfileSession, store: HouseholdStore) {
        guard let profile = store.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            print("[DebugLaunch] -SelectProfile: no profile named \(name)")
            return
        }
        session.select(profile)
    }

    // MARK: -SourceProbe <name>

    /// Signs in to a household source and prints every step with timings
    /// (logins masked by SourceProbe itself).
    private static func runSourceProbe(named name: String, store: HouseholdStore) {
        guard let record = store.sources.first(where: { !$0.isRemoved && $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              let configuration = AppSourceMapping.configuration(from: record) else {
            print("[SourceProbe] No source named \(name) in this household")
            return
        }
        Task.detached(priority: .userInitiated) {
            await SourceProbe.run(configuration) { line in
                print("[SourceProbe] \(line)")
                fflush(stdout)
            }
        }
    }

    // MARK: -OpenRoute, -AutoPlay

    private static func openRoute(_ route: LaunchOptions.Route, model: AppModel, catalog: CatalogService) async {
        switch route.target {
        case .itemKey(let key):
            model.pendingLaunchRoute = LaunchRoutes.route(kind: route.kind, itemKey: key)
        case .first:
            let found = await waitFor { LaunchRoutes.firstKey(of: route.kind, in: catalog) != nil }
            guard found, let key = LaunchRoutes.firstKey(of: route.kind, in: catalog) else {
                print("[DebugLaunch] -OpenRoute: the catalog has no \(route.kind.rawValue) yet")
                return
            }
            model.pendingLaunchRoute = LaunchRoutes.route(kind: route.kind, itemKey: key)
        }
    }

    private static func autoPlay(_ option: LaunchOptions.AutoPlay, services: AppServices) async {
        let catalog = services.catalog
        // A profile must be chosen first; -SelectProfile does that.
        guard await waitFor({ services.session.currentProfile != nil }) else { return }
        switch option {
        case .firstChannel:
            guard await waitFor({ !catalog.channels().isEmpty }), let channel = catalog.channels().first else { return }
            services.playback.play(PlaybackCoordinator.liveIntent(for: channel, queue: catalog.channels().map(\.key.rawValue)),
                                   sceneID: nil, layout: .compact)
        case .firstMovie:
            guard await waitFor({ !catalog.movies(limit: 1).isEmpty }), let movie = catalog.movies(limit: 1).first else { return }
            services.playback.play(PlayIntent(itemKey: movie.key.rawValue, kind: .movie, title: movie.name, artworkURL: movie.posterURL),
                                   sceneID: nil, layout: .compact)
        }
    }

    /// Polls until `condition` holds or the wait ends; true when it held.
    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + catalogWait
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return true
    }

    // MARK: -InitializeCloudKitSchema YES

    /// The schema ritual's first half. `scripts/cloudkit/init-schema.sh`
    /// waits for one of the two marker lines, so each is printed exactly and
    /// flushed. The work blocks while CloudKit answers, so it runs off the
    /// main actor; no real store is opened on this launch.
    static func runSchemaInitializer(model: AppModel) {
        let container = AppModel.containerIdentifier
        Task.detached(priority: .userInitiated) {
            let mark = "[CloudKitSchemaInitializer]"
            let outcome: String
            do {
                let lines = try HouseholdStore.initializeCloudKitSchema(containerIdentifier: container)
                lines.forEach { print($0) }
                print("\(mark) Schema sent to Development")
                outcome = String(localized: "Schema sent to Development. Deploy it to Production in the CloudKit Console.")
            } catch {
                print("\(mark) Failed: \(error.localizedDescription)")
                outcome = String(localized: "Failed: \(error.localizedDescription)")
            }
            fflush(stdout)
            await MainActor.run { model.schemaInitializerFinished(outcome) }
        }
    }
}

/// The demo seed's choices, apart from the store.
enum DemoSeed {
    /// The mockup's favorite channels when the catalog has them, else the
    /// first five.
    static func favoriteChannels(_ channels: [CatalogChannel]) -> [CatalogChannel] {
        let wanted = ["Cityline News", "Fieldhouse Sports", "Lantern Drama", "Little Owl Kids", "Northwind Docs"]
        let named = wanted.compactMap { name in channels.first { $0.name == name } }
        return named.isEmpty ? Array(channels.prefix(5)) : named
    }

    /// The demo provider's children's categories: live "Kids", movies
    /// "Family", shows "Kids".
    static func kidsCategoryIDs(_ categories: [CatalogCategory]) -> Set<String> {
        let names: Set<String> = ["kids", "family", "children", "cartoons", "animation"]
        return Set(categories.filter { !$0.isAdult && names.contains($0.name.lowercased()) }.map(\.id))
    }
}
#endif

import CatalogKit
import Core

/// `-OpenRoute`'s target as a route. Outside `#if DEBUG` so the mapping can
/// be tested; only Debug launches use it.
enum LaunchRoutes {
    static func route(kind: LaunchOptions.Route.Kind, itemKey: String) -> HearthRoute {
        switch kind {
        case .series: .series(itemKey: itemKey)
        case .movie: .movie(itemKey: itemKey)
        case .channel: .channel(itemKey: itemKey)
        }
    }

    @MainActor
    static func firstKey(of kind: LaunchOptions.Route.Kind, in catalog: CatalogService) -> String? {
        switch kind {
        case .series: catalog.series(limit: 1).first?.key.rawValue
        case .movie: catalog.movies(limit: 1).first?.key.rawValue
        case .channel: catalog.channels().first?.key.rawValue
        }
    }
}
