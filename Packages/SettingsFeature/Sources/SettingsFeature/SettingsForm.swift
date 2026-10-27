import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI

// Settings as one grouped Form: native pickers and the Mac's Settings-window
// feel (MAC-4), dressed in Hearth's dark palette — cards on `surface`, small
// caps section labels as on Household, amber for actions.

struct SettingsForm: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout

    var body: some View {
        Form {
            // Settings is a tab on the TV, the one place to switch profile
            // and reach Household from.
            if layout == .tv {
                TVProfileSection()
            }
            // The freshest copy of the current profile, so a language picked
            // a moment ago (or on another device) shows at once.
            if let current = session.currentProfile {
                let profile = store.profiles.first { $0.id == current.id } ?? current
                if !profile.isGuest {
                    PlaybackSection(profile: profile)
                }
            }
            // A Guest is a visitor: it doesn't get to decide what this device
            // opens into (PRF-2, PRF-5).
            if !session.isGuest {
                DeviceSection()
            }
            SourcesSection()
            CloudSection()
            StorageSection()
            AboutSection()
        }
        .formStyle(.grouped)
        .hearthScrollContentBackgroundHidden()
        .font(.hearthBody)
        .hearthTVScaledText(layout == .tv)
        .hearthScreenBackground()
    }
}

/// The TV's first section: who is watching, Switch profile, Household.
private struct TVProfileSection: View {
    @Environment(ProfileSession.self) private var session

    var body: some View {
        Section {
            if let profile = session.currentProfile {
                Button {
                    session.signOut()
                } label: {
                    HStack(spacing: 18) {
                        AvatarTile(name: profile.name, palette: profile.avatarColor, symbol: profile.avatarSymbol, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.hearthText(15, weight: .semibold, relativeTo: .body))
                            Text("Switch profile", bundle: .module)
                                .font(.hearthFootnote)
                                .foregroundStyle(HearthColor.textSecondary)
                        }
                    }
                }
                .settingsRows()
            }
            if !session.isKids, !session.isGuest {
                NavigationLink(value: HearthRoute.household) {
                    Label {
                        Text("Household", bundle: .module)
                    } icon: {
                        Image(systemName: "person.2").foregroundStyle(HearthColor.accent)
                    }
                }
                .settingsRows()
            }
        } header: {
            SectionLabel(String(localized: "Profile", bundle: .module))
        }
    }
}

// MARK: - Shared styling

extension View {
    /// A Form section's rows on Hearth's card colour, with Household's
    /// hairline between them.
    fileprivate func settingsRows() -> some View {
        self
            .listRowBackground(HearthColor.surface)
            .hearthListRowSeparatorTint(HearthColor.hairline)
    }
}

/// A section footer in Hearth's footnote style.
private struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.hearthFootnote)
            .foregroundStyle(HearthColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row label: amber glyph, primary text.
private struct SettingsLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
                .font(.hearthBody)
                .foregroundStyle(HearthColor.textPrimary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(HearthColor.accent)
        }
    }
}

// MARK: - Playback (PLY-6)

/// The current profile's preferred audio and subtitle languages: the player
/// picks matching tracks when a stream has them. Saved to the profile, so
/// they follow it to every device. Hidden for a Guest, which keeps nothing.
private struct PlaybackSection: View {
    let profile: ProfileRecord

    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session

    var body: some View {
        let canEdit = store.household.currentRole.canManage
        let options = LanguageOptions.options(including: [profile.audioLanguage, profile.subtitleLanguage])
        Section {
            Picker(selection: language(\.audioLanguage)) {
                Text("Automatic", bundle: .module, comment: "Audio language: the stream's own default").tag(String?.none)
                ForEach(options) { option in
                    Text(option.name).tag(Optional(option.code))
                }
            } label: {
                SettingsLabel(String(localized: "Audio language", bundle: .module), systemImage: "speaker.wave.2")
            }
            Picker(selection: language(\.subtitleLanguage)) {
                Text("Off", bundle: .module, comment: "Subtitles: none chosen automatically").tag(String?.none)
                ForEach(options) { option in
                    Text(option.name).tag(Optional(option.code))
                }
            } label: {
                SettingsLabel(String(localized: "Subtitles", bundle: .module), systemImage: "captions.bubble")
            }
        } header: {
            SectionLabel(String(localized: "Playback", bundle: .module))
        } footer: {
            SettingsFooter(canEdit
                ? String(localized: "Picked automatically when a stream has them. Saved to \(profile.name)'s profile on every device; you can still switch tracks in the player.", bundle: .module)
                : String(localized: "Only the household's owner and managers can change profile settings. You can still switch tracks in the player.", bundle: .module))
        }
        .disabled(!canEdit)
        .settingsRows()
    }

    private func language(_ keyPath: WritableKeyPath<ProfileRecord, String?>) -> Binding<String?> {
        Binding(
            get: { profile[keyPath: keyPath]?.lowercased() },
            set: { newValue in
                guard profile[keyPath: keyPath]?.lowercased() != newValue else { return }
                var updated = profile
                updated[keyPath: keyPath] = newValue
                store.updateProfile(updated)
                // The session holds a snapshot of the profile; re-read it so
                // the next play picks up the new languages.
                session.refresh()
            }
        )
    }
}

// MARK: - This device (PRF-2)

/// Which profile this device opens at launch without asking. Kept in this
/// device's UserDefaults by `ProfileSession`, never synced.
private struct DeviceSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session

    /// A locked profile waiting for its PIN before it becomes always-open.
    @State private var pinRequest: ProfileRecord?
    @State private var pin = ""
    @State private var pinRejected = false

    var body: some View {
        Section {
            Picker(selection: alwaysOpen) {
                Text("Ask who's watching", bundle: .module).tag(UUID?.none)
                ForEach(AlwaysOpenRule.choices(store.profiles, current: session.alwaysOpenProfileID)) { profile in
                    Text(Self.choiceName(profile)).tag(Optional(profile.id))
                }
            } label: {
                SettingsLabel(String(localized: "Always open", bundle: .module), systemImage: "person.crop.square")
            }
        } header: {
            SectionLabel(String(localized: "This device", bundle: .module))
        } footer: {
            SettingsFooter(String(localized: "Opens straight into this profile at launch, without asking who's watching. Only this device is affected; you can still switch profiles at any time.", bundle: .module))
        }
        .settingsRows()
        .alert(
            Text("Enter PIN", bundle: .module),
            isPresented: Binding(get: { pinRequest != nil }, set: { if !$0 { pinRequest = nil } }),
            presenting: pinRequest
        ) { profile in
            SecureField(String(localized: "PIN", bundle: .module), text: $pin)
                .numberPadKeyboard()
            Button(role: .cancel) {
                pin = ""
            } label: {
                Text("Cancel", bundle: .module)
            }
            Button {
                confirm(profile)
            } label: {
                Text("Always open", bundle: .module)
            }
        } message: { profile in
            Text("\(profile.name) is locked with a PIN. Enter it to open this device straight into \(profile.name).", bundle: .module)
        }
        .alert(Text("That PIN isn't right", bundle: .module), isPresented: $pinRejected) {
            Button(role: .cancel) {} label: { Text("OK", bundle: .module) }
        }
    }

    /// The selection. An always-open id the household no longer has reads as
    /// "Ask", as `ProfileSession.restore` treats it.
    private var alwaysOpen: Binding<UUID?> {
        Binding(
            get: {
                guard let id = session.alwaysOpenProfileID, store.profiles.contains(where: { $0.id == id }) else { return nil }
                return id
            },
            set: { newValue in
                guard let newValue, let profile = store.profiles.first(where: { $0.id == newValue }) else {
                    session.alwaysOpenProfileID = nil
                    return
                }
                if AlwaysOpenRule.needsPIN(for: profile, currentProfileID: session.currentProfile?.id) {
                    pin = ""
                    pinRequest = profile
                } else {
                    session.alwaysOpenProfileID = profile.id
                }
            }
        )
    }

    private func confirm(_ profile: ProfileRecord) {
        defer { pin = "" }
        if store.verifyPIN(pin, for: profile.id) {
            session.alwaysOpenProfileID = profile.id
        } else {
            pinRejected = true
        }
    }

    /// "Bhavik", "Kids · Kids profile", "Anya · PIN".
    static func choiceName(_ profile: ProfileRecord) -> String {
        var parts = [profile.name]
        switch profile.kind {
        case .kids: parts.append(String(localized: "Kids profile", bundle: .module))
        case .guest: parts.append(String(localized: "Guest", bundle: .module))
        case .standard: break
        }
        if profile.hasPIN { parts.append(String(localized: "PIN", bundle: .module)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Sources

/// Each source's last catalog and guide download, and "Refresh everything
/// now" (SRC-5, SRC-6 force).
private struct SourcesSection: View {
    @Environment(CatalogService.self) private var catalog
    @Environment(ProfileSession.self) private var session
    @Environment(\.openRoute) private var openRoute

    @State private var refreshingAll = false

    var body: some View {
        Section {
            if catalog.sources.isEmpty {
                Text("No sources yet. Add a portal, Xtream login or playlist in Household.", bundle: .module)
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textSecondary)
                    .padding(.vertical, 4)
                if session.canManageHousehold {
                    // Through the app rather than a link: the Mac opens
                    // Household in the main window, not in Settings'.
                    Button {
                        openRoute(.household)
                    } label: {
                        SettingsLabel(String(localized: "Open Household", bundle: .module), systemImage: "house")
                    }
                }
            } else {
                ForEach(catalog.sources) { source in
                    SourceStatusRow(source: source, state: catalog.refreshStates[source.id])
                }
                Button {
                    Task { await refreshAll() }
                } label: {
                    HStack {
                        SettingsLabel(String(localized: "Refresh everything now", bundle: .module), systemImage: "arrow.clockwise")
                        Spacer(minLength: 8)
                        if refreshingAll || isAnyRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("Refreshing", bundle: .module))
                        }
                    }
                    .frame(minHeight: HearthMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                .disabled(refreshingAll)
            }
        } header: {
            SectionLabel(String(localized: "Sources", bundle: .module))
        } footer: {
            SettingsFooter(String(localized: "Hearth refreshes catalogs every day and guides every six hours on its own. Everything downloads straight from your provider to this device.", bundle: .module))
        }
        .settingsRows()
    }

    private var isAnyRefreshing: Bool {
        catalog.refreshStates.values.contains {
            if case .refreshing = $0.phase { return true }
            return false
        }
    }

    /// One source at a time, as the catalog's own stale refresh does: a
    /// Stalker portal allows one session per MAC, and several imports at
    /// once would only fight over the disk. Carries on if Settings closes.
    private func refreshAll() async {
        refreshingAll = true
        defer { refreshingAll = false }
        for source in catalog.sources {
            if Task.isCancelled { return }
            await catalog.refresh(sourceID: source.id, force: true)
        }
    }
}

private struct SourceStatusRow: View {
    let source: SourceConfiguration
    let state: SourceRefreshState?

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(alignment: .top, spacing: 12) {
                CardTile(text: Self.code(for: source.kind), size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                        .font(.hearthText(15, weight: .medium, relativeTo: .body))
                        .foregroundStyle(HearthColor.textPrimary)
                    statusLine(now: context.date)
                    if let counts = countsLine {
                        Text(counts)
                            .font(.hearthCaption)
                            .foregroundStyle(HearthColor.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func statusLine(now: Date) -> some View {
        switch state?.phase ?? .idle {
        case .refreshing(let progress, let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message.isEmpty ? String(localized: "Refreshing…", bundle: .module) : message)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                if let progress {
                    HearthProgressBar(value: progress, height: 3)
                        .frame(maxWidth: 220)
                }
            }
        case .failed(let message):
            Text(message)
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.danger)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            Text(RefreshTimeText.sourceLine(catalog: state?.catalogRefreshedAt, guide: state?.guideRefreshedAt, now: now))
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
    }

    /// "1,204 channels · 40 movies · 10 shows", once something is imported.
    private var countsLine: String? {
        guard let state, state.channelCount + state.movieCount + state.seriesCount > 0 else { return nil }
        var parts: [String] = []
        if state.channelCount > 0 { parts.append(String(localized: "\(state.channelCount) channels", bundle: .module)) }
        if state.movieCount > 0 { parts.append(String(localized: "\(state.movieCount) movies", bundle: .module)) }
        if state.seriesCount > 0 { parts.append(String(localized: "\(state.seriesCount) shows", bundle: .module)) }
        return parts.joined(separator: " · ")
    }

    /// The type code Household's source rows use.
    static func code(for kind: SourceKind) -> String {
        switch kind {
        case .stalker: "MAC"
        case .xtream: "XC"
        case .m3u: "M3U"
        }
    }
}

// MARK: - iCloud

private struct CloudSection: View {
    @Environment(HouseholdStore.self) private var store
    @State private var refreshing = false

    private var isCloud: Bool {
        if case .cloud = store.mode { return true }
        return false
    }

    var body: some View {
        Section {
            TimelineView(.everyMinute) { context in
                LabeledContent {
                    Text(SyncStatusText.text(store.syncStatus, now: context.date))
                        .font(.hearthFootnote)
                        .foregroundStyle(SyncStatusText.isProblem(store.syncStatus) ? HearthColor.danger : HearthColor.textSecondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    SettingsLabel(String(localized: "Status", bundle: .module), systemImage: "icloud")
                }
            }
            if let error = store.lastWriteError {
                Text("The last change wasn't saved: \(error)", bundle: .module)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task {
                    refreshing = true
                    await store.refreshFromCloud()
                    refreshing = false
                }
            } label: {
                HStack {
                    SettingsLabel(String(localized: "Refresh from iCloud", bundle: .module), systemImage: "arrow.triangle.2.circlepath.icloud")
                    Spacer(minLength: 8)
                    if refreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("Refreshing", bundle: .module))
                    }
                }
                .frame(minHeight: HearthMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .disabled(refreshing || !isCloud || store.syncStatus == .noAccount)
        } header: {
            SectionLabel(String(localized: "iCloud", bundle: .module))
        } footer: {
            SettingsFooter(isCloud
                ? String(localized: "Profiles, favorites, progress and sources sync through iCloud on their own. This asks iCloud for changes now.", bundle: .module)
                : String(localized: "iCloud is off in this build: the household lives on this device until the app quits.", bundle: .module))
        }
        .settingsRows()
    }
}

// MARK: - Storage

private struct StorageSection: View {
    @State private var cacheBytes = 0
    @State private var cleared = false

    var body: some View {
        Section {
            LabeledContent {
                Text(CacheSizeText.text(bytes: cacheBytes))
                    .font(.hearthMono(13, relativeTo: .footnote))
                    .foregroundStyle(HearthColor.textSecondary)
            } label: {
                SettingsLabel(String(localized: "Image cache", bundle: .module), systemImage: "photo.stack")
            }
            Button {
                // Posters and logos load through URLSession.shared
                // (AsyncImage), so they live in the shared URL cache.
                URLCache.shared.removeAllCachedResponses()
                cleared = true
                measure()
            } label: {
                HStack {
                    SettingsLabel(String(localized: "Clear image cache", bundle: .module), systemImage: "trash")
                    Spacer(minLength: 8)
                    if cleared {
                        Text("Cleared", bundle: .module)
                            .font(.hearthFootnote)
                            .foregroundStyle(HearthColor.success)
                    }
                }
                .frame(minHeight: HearthMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
        } header: {
            SectionLabel(String(localized: "Storage", bundle: .module))
        } footer: {
            SettingsFooter(String(localized: "Channel lists, the guide and posters are kept on this device and can always be rebuilt from your providers. Clearing them never touches your household in iCloud.", bundle: .module))
        }
        .settingsRows()
        .onAppear(perform: measure)
    }

    private func measure() {
        cacheBytes = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
    }
}

// MARK: - About

private struct AboutSection: View {
    var body: some View {
        Section {
            HStack(spacing: 12) {
                HearthLogo()
                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .accessibilityHidden(true)
            LabeledContent {
                Text(verbatim: AppVersionText.current())
                    .font(.hearthMono(13, relativeTo: .footnote))
                    .foregroundStyle(HearthColor.textSecondary)
                    .hearthTextSelectable()
            } label: {
                SettingsLabel(String(localized: "Version", bundle: .module), systemImage: "info.circle")
            }
            // The App Review 5.2 posture: a player, not a provider.
            VStack(alignment: .leading, spacing: 8) {
                Text("Hearth plays only services you already subscribe to; it ships no channels or playlists.", bundle: .module)
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textPrimary)
                Text("No analytics, ads or tracking. Logins stay encrypted in your iCloud and are never logged.", bundle: .module)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
            NavigationLink {
                AcknowledgementsView()
            } label: {
                SettingsLabel(String(localized: "Acknowledgements", bundle: .module), systemImage: "doc.text")
            }
        } header: {
            SectionLabel(String(localized: "About", bundle: .module))
        }
        .settingsRows()
    }
}
