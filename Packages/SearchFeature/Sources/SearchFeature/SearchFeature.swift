import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.

/// One search across channels, the next 24 hours of the guide, movies and
/// shows from every source, grouped by type (SRCH-1…SRCH-3).
///
/// Host it inside a `NavigationStack` that maps `HearthRoute` (posters push
/// `.movie` / `.series`, guide hits `.channel`); it sets its own navigation
/// title. Every query is a read of the catalog on this device, and the
/// catalog applies the current profile's filter, so a Kids profile only
/// finds what it may watch (SRCH-3). A source that keeps only part of its
/// movies and shows here (a big Stalker portal) is also asked, once the
/// typing settles, and what it finds joins the catalog: the owner chose
/// complete answers over the query staying on the device (SRCH-2).
public struct SearchView: View {
    let initialQuery: String
    public init(initialQuery: String = "") { self.initialQuery = initialQuery }

    @Environment(ProfileSession.self) private var session

    public var body: some View {
        let profileID = session.currentProfile?.id
        // A fresh screen per profile: its own recent searches, and no
        // results left over from the profile before (SRCH-3).
        SearchScreen(
            initialQuery: initialQuery,
            recentsKey: RecentSearches.storageKey(profileID: profileID),
            keepsRecents: !session.isGuest
        )
        .id(profileID)
    }
}

/// The results of one search, kept until the next one lands so the list
/// doesn't flash empty between keystrokes.
private struct SearchOutcome {
    var normalizedQuery: String
    var groups: SearchResultGroups
}

private struct SearchScreen: View {
    let initialQuery: String
    let keepsRecents: Bool

    @Environment(CatalogService.self) private var catalog
    @Environment(\.hearthLayout) private var layout
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    @AppStorage private var recentsStorage: String
    @State private var query: String
    @State private var outcome: SearchOutcome?
    @State private var expanded: Set<SearchSection> = []
    @State private var hasAppeared = false
    @FocusState private var fieldFocused: Bool

    init(initialQuery: String, recentsKey: String, keepsRecents: Bool) {
        self.initialQuery = initialQuery
        self.keepsRecents = keepsRecents
        _recentsStorage = AppStorage(wrappedValue: "", recentsKey)
        _query = State(initialValue: initialQuery)
    }

    private var recents: RecentSearches { RecentSearches(storage: recentsStorage) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if layout == .tv {
            tvBody
        } else {
            touchBody
        }
    }

    // MARK: TV

    /// The Apple TV: tvOS's search keyboard at the top (`.searchable`), the
    /// results as shelves under it. A query is remembered when submitted.
    private var tvBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HearthTVMetrics.shelfSpacing) {
                tvContent
            }
            .padding(.bottom, 60)
        }
        .scrollClipDisabled()
        .searchable(text: $query, prompt: Text("Channels, programmes, movies, shows", bundle: .module))
        .autocorrectionDisabled()
        .onSubmit(of: .search) { remember(query) }
        .hearthScreenBackground()
        .task(id: SearchRequest(query: query, revision: catalog.revision)) {
            await runSearch()
        }
        .onChange(of: query) { _, _ in expanded = [] }
    }

    @ViewBuilder private var tvContent: some View {
        if trimmedQuery.isEmpty {
            if keepsRecents, !recents.isEmpty {
                TVShelf(String(localized: "Recent searches", bundle: .module), spacing: 20) {
                    ForEach(recents.items, id: \.self) { item in
                        Button(item) {
                            query = item
                            remember(item)
                        }
                        .buttonStyle(.hearthTV)
                    }
                } accessory: {
                    Button(String(localized: "Clear", bundle: .module)) {
                        recentsStorage = RecentSearches().storage
                    }
                    .buttonStyle(.hearthTV)
                }
            } else {
                SearchTVNotice(
                    systemName: "magnifyingglass",
                    title: String(localized: "Search everything", bundle: .module),
                    message: catalog.searchesProviders
                    ? String(localized: "Channels, the next 24 hours of the guide, movies and shows from all your sources. Movies and shows are also looked up on your provider.", bundle: .module)
                    : String(localized: "Channels, the next 24 hours of the guide, movies and shows from all your sources. What you type stays on this device.", bundle: .module)
                )
            }
        } else if catalog.sources.isEmpty {
            SearchTVNotice(
                systemName: "antenna.radiowaves.left.and.right",
                title: String(localized: "No sources yet", bundle: .module),
                message: String(localized: "Add a portal, Xtream login or playlist from Hearth on your iPhone, iPad or Mac, then search here.", bundle: .module)
            )
        } else if let outcome {
            if outcome.groups.isEmpty {
                SearchTVNotice(
                    systemName: "magnifyingglass",
                    title: String(localized: "No results for “\(trimmedQuery)”", bundle: .module),
                    message: String(localized: "Check the spelling, or try a shorter name or a channel number.", bundle: .module)
                )
            } else {
                SearchTVResults(groups: outcome.groups) { remember(query) }
            }
        } else {
            ProgressView()
                .tint(HearthColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    // MARK: Phone and sidebar

    private var touchBody: some View {
        ScrollView {
            content
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: layout == .sidebar ? 1100 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .hearthScreenBackground()
        .navigationTitle(Text("Search", bundle: .module))
        .largeNavigationTitle()
        .task(id: SearchRequest(query: query, revision: catalog.revision)) {
            await runSearch()
        }
        .task {
            // First arrival only: coming back from a movie or channel pushed
            // from the results shouldn't raise the keyboard again.
            guard !hasAppeared else { return }
            hasAppeared = true
            // A query handed over by the Mac sidebar's "Search everything"
            // was submitted there: it counts as a search.
            if !initialQuery.isEmpty { remember(initialQuery) }
            // Focused on arrival (SRCH-1), after the push or tab switch has
            // settled: focusing during the transition is dropped on iOS.
            try? await Task.sleep(for: .milliseconds(350))
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in expanded = [] }
        // The app may hand over a new query to a screen already showing (the
        // Mac sidebar's search submitted again): take it, as typing would.
        .onChange(of: initialQuery) { _, newValue in
            guard !newValue.isEmpty, newValue != query else { return }
            query = newValue
            remember(newValue)
        }
    }

    private var horizontalPadding: CGFloat {
        layout == .sidebar ? 32 : HearthMetrics.screenPadding
    }

    // MARK: Search bar

    private var searchBar: some View {
        SearchField(
            String(localized: "Channels, programmes, movies, shows", bundle: .module, comment: "Search field placeholder"),
            text: $query,
            focus: $fieldFocused,
            onSubmit: { remember(query) }
        )
        // Channel and film names aren't dictionary words: autocorrect would
        // turn "Sky Cinema HD" into something no catalog holds.
        .autocorrectionDisabled()
        .frame(maxWidth: layout == .sidebar ? 640 : .infinity)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: layout == .sidebar ? 1100 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(HearthColor.background)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if trimmedQuery.isEmpty {
            idleContent
        } else if catalog.sources.isEmpty {
            EmptyStateView(
                systemName: "antenna.radiowaves.left.and.right",
                title: String(localized: "No sources yet", bundle: .module),
                message: String(localized: "Add a portal, Xtream login or playlist in Household, then search here.", bundle: .module)
            )
            .padding(.top, 40)
        } else if let outcome {
            if catalog.providerSearchesRunning > 0 {
                ProviderSearchNote()
            }
            if outcome.groups.isEmpty {
                if catalog.providerSearchesRunning == 0 { noResults(for: outcome) }
            } else {
                SearchResultsList(
                    groups: outcome.groups,
                    showsSourceNames: catalog.sources.count > 1,
                    expanded: $expanded,
                    onActivate: { remember(query) }
                )
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(HearthColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .accessibilityLabel(Text("Searching", bundle: .module))
        }
    }

    /// Nothing typed: the recent searches, or what Search covers.
    @ViewBuilder private var idleContent: some View {
        if keepsRecents, !recents.isEmpty {
            RecentSearchesSection(
                recents: recents,
                onPick: { picked in
                    query = picked
                    remember(picked)
                },
                onRemove: { recentsStorage = recents.removing($0).storage },
                onClear: { recentsStorage = RecentSearches().storage }
            )
        } else {
            EmptyStateView(
                systemName: "magnifyingglass",
                title: String(localized: "Search everything", bundle: .module),
                message: catalog.searchesProviders
                    ? String(localized: "Channels, the next 24 hours of the guide, movies and shows from all your sources. Movies and shows are also looked up on your provider.", bundle: .module)
                    : String(localized: "Channels, the next 24 hours of the guide, movies and shows from all your sources. What you type stays on this device.", bundle: .module)
            )
            .padding(.top, 40)
        }
    }

    private func noResults(for outcome: SearchOutcome) -> some View {
        let refreshing = catalog.refreshStates.values.contains {
            if case .refreshing = $0.phase { return true }
            return false
        }
        return EmptyStateView(
            systemName: "magnifyingglass",
            title: String(localized: "No results for “\(trimmedQuery)”", bundle: .module),
            message: refreshing
                ? String(localized: "Your catalog is still downloading. Results will appear as it arrives.", bundle: .module)
                : String(localized: "Check the spelling, or try a shorter name or a channel number.", bundle: .module)
        )
        .padding(.top, 40)
    }

    // MARK: Actions

    /// Runs the search for the current text: at once for a catalog change
    /// (same query, new revision), after the debounce for typing.
    private func runSearch() async {
        let normalized = SearchKey.normalize(query)
        guard !normalized.isEmpty else {
            outcome = nil
            return
        }
        if let outcome, outcome.normalizedQuery != normalized {
            try? await Task.sleep(for: SearchRequest.debounce)
            if Task.isCancelled { return }
        }
        let now = Date.now
        let results = catalog.search(query, now: now, limitPerGroup: SearchResultLimits.perGroup)
        outcome = SearchOutcome(normalizedQuery: normalized, groups: SearchResultGroups(results, now: now))

        // Stalker portals have no full guide: ask for the short guide of the
        // channels on screen so their "now" lines fill in. Unstructured on
        // purpose — the catalog marks channels as asked when it starts, so a
        // load cancelled by the next keystroke wouldn't be retried for half
        // an hour. It bumps `revision` when it lands, which re-runs this.
        let visible = Array(results.channels.prefix(SearchResultLimits.collapsedCount(for: .channels, layout: layout)))
        if !visible.isEmpty {
            Task { await catalog.loadShortGuide(for: visible) }
        }

        // A big portal's titles aren't all here: once the typing settles,
        // ask it too. Unstructured for the same reason as the short guides;
        // its results bump `revision`, which re-runs this with them in.
        guard catalog.searchesProviders else { return }
        try? await Task.sleep(for: SearchRequest.providerDebounce)
        if Task.isCancelled { return }
        let settled = query
        Task { await catalog.searchProviders(settled) }
    }

    /// Keeps the query in this profile's recent searches (not for a Guest).
    private func remember(_ text: String) {
        guard keepsRecents else { return }
        let updated = recents.adding(text)
        if updated != recents { recentsStorage = updated.storage }
    }
}

// MARK: - Recent searches

private struct RecentSearchesSection: View {
    let recents: RecentSearches
    let onPick: (String) -> Void
    let onRemove: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HearthMetrics.itemSpacing) {
            SectionHeader(String(localized: "Recent searches", bundle: .module)) {
                Button(action: onClear) {
                    Text("Clear", bundle: .module)
                        .padding(.horizontal, 4)
                        .frame(minWidth: HearthMetrics.minimumHitTarget, minHeight: HearthMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear recent searches", bundle: .module))
            }
            GroupedCard(footer: String(localized: "Recent searches are kept on this device only.", bundle: .module)) {
                ForEach(recents.items, id: \.self) { item in
                    RecentSearchRow(text: item, onPick: { onPick(item) }, onRemove: { onRemove(item) })
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

private struct RecentSearchRow: View {
    let text: String
    let onPick: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onPick) {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HearthColor.textTertiary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.hearthBody)
                        .foregroundStyle(HearthColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hearthTile)
            .accessibilityLabel(Text(text))
            .accessibilityHint(Text("Searches again", bundle: .module))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HearthColor.glyphMuted)
                    .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -10)
            .accessibilityLabel(Text("Remove “\(text)” from recent searches", bundle: .module))
        }
    }
}

/// "Also searching your provider…" over the results while a big portal is
/// asked.
private struct ProviderSearchNote: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(HearthColor.textSecondary)
            Text("Also searching your provider…", bundle: .module)
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
