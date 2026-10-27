import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// Timeline guide or plain list, remembered per device.
enum LivePresentation: String, CaseIterable, Sendable {
    case guide
    case list
}

/// Guide or multi-view, in the sidebar layout's toolbar (MAC-5).
enum LiveMode: String, CaseIterable, Hashable, Sendable {
    case guide
    case multiView

    var title: String {
        switch self {
        case .guide: String(localized: "Guide")
        case .multiView: String(localized: "Multi-view")
        }
    }
}

/// What one load of the screen's data produced.
private struct LiveContent {
    var chips: [LiveChip] = []
    var chip: LiveChip = .all
    var channels: [CatalogChannel] = []
    var favoriteKeys: Set<String> = []
    var guideRange: ClosedRange<Date>?
    var isLoaded = false
}

/// Everything that should re-run the load when it changes.
private struct LiveContentKey: Hashable {
    var chipID: String?
    var catalogRevision: Int
    var storeRevision: Int
    var profileID: UUID?
    var isGuest: Bool
}

/// Live TV (mockup 03): the title, the category chips, then the timeline
/// guide or the channel list, and the programme card over them. In the
/// sidebar layout the toolbar carries the title, Guide | Multi-view, the
/// list toggle and search; multi-view replaces the guide in place.
struct LiveTVScreen: View {
    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The last chip per profile (JSON, see `ChipMemory`).
    @AppStorage("liveTV.lastChipByProfile") private var chipMemory = ""
    @AppStorage("liveTV.presentation") private var presentationRaw = LivePresentation.guide.rawValue
    @SceneStorage("liveTV.mode") private var modeRaw = LiveMode.guide.rawValue

    /// The chip the user picked this session; nil until they pick one (the
    /// remembered chip is used meanwhile).
    @State private var pickedChipID: String?
    @State private var content = LiveContent()
    @State private var selection: GuideSelection?
    @State private var showsSearch = false
    @State private var showsFavoritesOrder = false
    @State private var cache = GuideProgrammeCache()
    @State private var shortGuides = ShortGuideRequests()
    @ScaledMetric(relativeTo: .footnote) private var scaledRowHeight: CGFloat = 60

    private var presentation: LivePresentation {
        LivePresentation(rawValue: presentationRaw) ?? .guide
    }

    private var mode: LiveMode {
        layout == .sidebar ? (LiveMode(rawValue: modeRaw) ?? .guide) : .guide
    }

    private var profileID: UUID? { session.currentProfile?.id }
    private var keepsFavorites: Bool { profileID != nil && !session.isGuest }

    var body: some View {
        Group {
            if mode == .multiView {
                MultiViewScreen(showsModePicker: false) { modeRaw = LiveMode.guide.rawValue }
            } else {
                guideScreen
            }
        }
        .navigationTitle(Text("Live TV"))
        .toolbar(layout == .compact ? .hidden : .automatic, for: .automatic)
        .toolbar {
            if layout == .sidebar {
                ToolbarItem(placement: .principal) {
                    SegmentedPills(String(localized: "Live TV view"), options: LiveMode.allCases, selection: modeBinding, size: .compact) { $0.title }
                }
            }
        }
    }

    private var modeBinding: Binding<LiveMode> {
        Binding(get: { mode }, set: { modeRaw = $0.rawValue })
    }

    // MARK: Guide screen

    private var guideScreen: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            VStack(spacing: 0) {
                if layout == .compact {
                    header
                }
                chipRow
                    .padding(.top, layout == .compact ? 6 : 8)
                main(now: now)
                    .padding(.top, 8)
            }
            .overlay(alignment: .bottom) {
                card(now: now)
            }
        }
        .hearthScreenBackground()
        .toolbar {
            if layout == .sidebar {
                ToolbarItemGroup(placement: .primaryAction) {
                    presentationToggle
                    Button {
                        showsSearch = true
                    } label: {
                        Label("Search channels", systemImage: "magnifyingglass")
                    }
                    .hearthKeyboardShortcut("f", modifiers: .command)
                }
            }
        }
        .sheet(isPresented: $showsSearch) {
            ChannelSearchSheet { channel, results in
                play(LiveIntents.live(channel, programme: catalog.nowAndNext(for: channel).now, queue: ChannelOrdering.queue(results)))
            } onOpenChannel: { channel in
                openRoute(.channel(itemKey: channel.key.rawValue))
            }
        }
        .sheet(isPresented: $showsFavoritesOrder) {
            FavoritesOrderSheet()
        }
        .task(id: contentKey) {
            reload()
        }
        .onChange(of: content.chip) { _, _ in
            selection = nil
        }
        .onChange(of: presentationRaw) { _, _ in
            selection = nil
        }
        .onChange(of: profileID) { _, _ in
            // Another profile has its own remembered chip.
            pickedChipID = nil
            selection = nil
        }
    }

    /// The phone's header: the large title, and round buttons for the list
    /// toggle and search, as in the mockup.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Live TV")
                .font(.hearthLargeTitle)
                .tracking(HearthMetrics.titleTracking)
                .foregroundStyle(HearthColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            IconCircleButton(
                systemName: presentation == .guide ? "list.bullet" : "calendar.day.timeline.left",
                label: presentation == .guide ? String(localized: "Show channel list") : String(localized: "Show guide")
            ) {
                togglePresentation()
            }
            IconCircleButton(systemName: "magnifyingglass", label: String(localized: "Search channels")) {
                showsSearch = true
            }
        }
        .padding(.horizontal, HearthMetrics.screenPadding)
        .padding(.top, 8)
    }

    private var presentationToggle: some View {
        Button {
            togglePresentation()
        } label: {
            if presentation == .guide {
                Label("Show channel list", systemImage: "list.bullet")
            } else {
                Label("Show guide", systemImage: "calendar.day.timeline.left")
            }
        }
    }

    private func togglePresentation() {
        presentationRaw = (presentation == .guide ? LivePresentation.list : .guide).rawValue
    }

    /// Favorites, All channels, then the live categories (FAV-1, LIV-1).
    private var chipRow: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(content.chips) { chip in
                        PillChip(chip.title, isSelected: chip == content.chip) {
                            select(chip)
                        }
                        .id(chip.id)
                    }
                    if content.chip == .favorites, keepsFavorites, content.channels.count > 1 {
                        IconCircleButton(systemName: "arrow.up.arrow.down", label: String(localized: "Reorder favorites"), size: 36) {
                            showsFavoritesOrder = true
                        }
                    }
                }
                .padding(.horizontal, layout == .compact ? HearthMetrics.screenPadding : 20)
            }
            .onChange(of: content.chip.id) { _, id in
                withAnimation(reduceMotion ? nil : .snappy) { reader.scrollTo(id, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Categories"))
    }

    private func select(_ chip: LiveChip) {
        pickedChipID = chip.id
        chipMemory = ChipMemory.remembering(chip.id, profileID: profileID, in: chipMemory)
    }

    // MARK: Content

    @ViewBuilder
    private func main(now: Date) -> some View {
        if !content.isLoaded {
            Color.clear
        } else if content.channels.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation == .guide {
            GeometryReader { proxy in
                GuideGridView(
                    channels: content.channels,
                    timeline: GuideTimeline.make(guideRange: content.guideRange, now: now, pointsPerMinute: metrics(width: proxy.size.width).pointsPerMinute),
                    metrics: metrics(width: proxy.size.width),
                    now: now,
                    revision: catalog.revision,
                    cache: cache,
                    shortGuides: shortGuides,
                    selection: $selection,
                    bottomInset: selection == nil ? 16 : 200,
                    listID: content.chip.id
                )
            }
        } else {
            ChannelListView(
                channels: content.channels,
                now: now,
                revision: catalog.revision,
                cache: cache,
                shortGuides: shortGuides,
                showsFavorites: keepsFavorites,
                favoriteKeys: content.favoriteKeys,
                bottomInset: 16,
                listID: content.chip.id,
                onToggleFavorite: toggleFavorite
            ) { action, channel, programme in
                perform(action, channel: channel, programme: programme, now: now)
            }
        }
    }

    private func metrics(width: CGFloat) -> GuideMetrics {
        GuideMetrics.make(width: width, rowHeight: min(scaledRowHeight, 112))
    }

    @ViewBuilder
    private func card(now: Date) -> some View {
        if let selection, presentation == .guide {
            ProgrammeCard(
                channel: selection.channel,
                programme: selection.programme,
                now: now,
                isFavorite: content.favoriteKeys.contains(selection.channel.key.rawValue),
                showsFavorite: keepsFavorites,
                showsClose: layout == .sidebar,
                onToggleFavorite: { toggleFavorite(selection.channel) },
                onAction: { action in perform(action, channel: selection.channel, programme: selection.programme, now: now) },
                onClose: { withAnimation(reduceMotion ? nil : .snappy) { self.selection = nil } }
            )
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(selection.channel.key.rawValue + (selection.programme?.id ?? ""))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if catalog.sources.isEmpty {
            EmptyStateView(
                systemName: "antenna.radiowaves.left.and.right",
                title: String(localized: "No sources yet"),
                message: String(localized: "Add your provider in Household and its channels show up here."),
                actionTitle: session.canManageHousehold ? String(localized: "Open Household") : nil,
                action: session.canManageHousehold ? { openRoute(.household) } : nil
            )
        } else if isRefreshing, content.chip != .favorites {
            VStack(spacing: 14) {
                ProgressView()
                Text("Loading channels…")
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            switch content.chip {
            case .favorites:
                EmptyStateView(
                    systemName: "heart",
                    title: String(localized: "No favorite channels yet"),
                    message: String(localized: "Tap the heart on a programme or a channel to keep it here, in the order you like."),
                    actionTitle: String(localized: "Show all channels")
                ) {
                    select(.all)
                }
            case .all:
                EmptyStateView(
                    systemName: "tv",
                    title: String(localized: "No channels"),
                    message: String(localized: "Your sources didn't list any live channels this profile can watch.")
                )
            case .category:
                EmptyStateView(
                    systemName: "square.stack",
                    title: String(localized: "Nothing in this category"),
                    message: String(localized: "It's empty, or hidden for this profile."),
                    actionTitle: String(localized: "Show all channels")
                ) {
                    select(.all)
                }
            }
        }
    }

    private var isRefreshing: Bool {
        catalog.refreshStates.values.contains { state in
            if case .refreshing = state.phase { return true }
            return false
        }
    }

    // MARK: Loading

    private var contentKey: LiveContentKey {
        LiveContentKey(
            chipID: pickedChipID,
            catalogRevision: catalog.revision,
            storeRevision: store.revision,
            profileID: profileID,
            isGuest: session.isGuest
        )
    }

    /// Reads the chips and the selected chip's channels. Runs when the chip,
    /// the profile, the catalog or the household changes — not per frame.
    private func reload() {
        let favoriteRecords = keepsFavorites ? (profileID.map { store.favorites(profileID: $0, kind: .channel) } ?? []) : []
        let favoriteKeys = favoriteRecords.map(\.itemKey)
        let chips = LiveChip.chips(categories: catalog.categories(kind: .live), showsFavorites: keepsFavorites)
        let remembered = pickedChipID ?? ChipMemory.remembered(in: chipMemory, profileID: profileID)
        let chip = LiveChip.resolve(rememberedID: remembered, chips: chips, hasFavorites: !favoriteKeys.isEmpty)
        let channels = ChipChannels.channels(for: chip, favoriteKeys: favoriteKeys, catalog: catalog)
        content = LiveContent(
            chips: chips,
            chip: chip,
            channels: channels,
            favoriteKeys: Set(favoriteKeys),
            guideRange: catalog.guideRange(),
            isLoaded: true
        )
        if let selection, !channels.contains(where: { $0.key == selection.channel.key }) {
            self.selection = nil
        }
    }

    // MARK: Actions

    private func perform(_ action: ProgrammeAction, channel: CatalogChannel, programme: CatalogProgramme?, now: Date) {
        play(LiveIntents.intent(for: action, channel: channel, programme: programme, now: now, queue: ChannelOrdering.queue(content.channels)))
    }

    private func toggleFavorite(_ channel: CatalogChannel) {
        guard keepsFavorites, let profileID else { return }
        store.toggleFavorite(profileID: profileID, itemKey: channel.key.rawValue, kind: .channel)
    }
}
