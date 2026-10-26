import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI
import UniformTypeIdentifiers

/// Add (nil) or edit a source: Stalker portal URL and MAC with advanced
/// fields, Xtream login, or M3U playlist by link or file; Test before saving
/// (SRC-1…SRC-4); remove or restore (SRC-9).
///
/// Built to be pushed (`HearthRoute.sourceEditor`): the back button leaves
/// without saving and Save is in the toolbar. In a sheet, use
/// `SourceEditorSheet`, which adds its own navigation, Cancel and a size for
/// the Mac. Only the owner and managers get the form (SRC-8); a watcher sees
/// why not, and never the login.
public struct SourceEditorView: View {
    let sourceID: UUID?

    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(CatalogService.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var isLoaded = false
    @State private var original: SourceRecord?
    @State private var draft = SourceDraft()
    @State private var initialDraft = SourceDraft()
    /// The id the source will be saved under, fixed when the editor opens so
    /// Test and an imported playlist file use the same one.
    @State private var draftID = UUID()
    @State private var showsAdvanced = false
    @State private var test: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var isImportingFile = false
    @State private var isCopyingFile = false
    @State private var fileError: String?
    @State private var isConfirmingRemove = false
    @State private var saveError: String?

    public init(sourceID: UUID?) {
        self.sourceID = sourceID
    }

    /// Where the Test button stands.
    enum TestState: Equatable {
        case idle
        case running
        /// The result, and the configuration it was for: a later edit to the
        /// login hides it.
        case finished(SourceTestResult, SourceConfiguration)
    }

    private var isNew: Bool { sourceID == nil }
    var isDirty: Bool { draft != initialDraft }

    public var body: some View {
        Group {
            if !session.canManageHousehold {
                EmptyStateView(
                    systemName: "lock",
                    title: String(localized: "Only the owner and managers can see logins"),
                    message: String(localized: "Ask the household's owner to change this source.")
                )
                .frame(maxHeight: .infinity)
            } else if !isLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isNew && original == nil {
                EmptyStateView(
                    systemName: "questionmark.folder",
                    title: String(localized: "This source is gone"),
                    message: String(localized: "Someone in the household deleted it.")
                )
                .frame(maxHeight: .infinity)
            } else {
                form
            }
        }
        .navigationTitle(title)
        .inlineNavigationTitle()
        .hearthScreenBackground()
        .toolbar {
            if session.canManageHousehold, isNew || original != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .disabled(!draft.isComplete || isCopyingFile)
                }
            }
        }
        .task { load() }
        .onDisappear { testTask?.cancel() }
    }

    private var title: Text {
        if isNew { return Text("Add Source") }
        return Text(original?.name ?? String(localized: "Source"))
    }

    // MARK: Form

    private var form: some View {
        Form {
            if let failure = lastRefreshFailure {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("The last update failed")
                                .font(.hearthText(15, weight: .medium, relativeTo: .body))
                            Text(failure)
                                .font(.hearthFootnote)
                                .foregroundStyle(HearthColor.textSecondary)
                                .textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HearthColor.danger)
                    }
                }
                .listRowBackground(HearthColor.surface)
            }
            kindSection
            detailsSection
            if draft.kind == .stalker {
                advancedSection
            }
            streamsSection
            testSection
            if !isNew {
                removeSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(.hearthBody)
        .tint(HearthColor.accent)
        .onChange(of: draft.macAddress) { _, typed in
            let formatted = MACAddress.formattedWhileTyping(typed)
            if formatted != typed { draft.macAddress = formatted }
        }
        .onChange(of: draft) { _, current in
            // A result belongs to the login it tested; a renamed source keeps it.
            if case .finished(_, let tested) = test, SourceMapping.connectionChanged(tested, current.configuration(id: draftID)) {
                test = .idle
            }
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: Self.playlistTypes) { result in
            switch result {
            case .success(let url): importPlaylist(url)
            case .failure(let error): fileError = error.localizedDescription
            }
        }
        .alert(String(localized: "Couldn't use that file"), isPresented: isShowing($fileError), presenting: fileError) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { Text($0) }
        .alert(String(localized: "Couldn't save"), isPresented: isShowing($saveError), presenting: saveError) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { Text($0) }
        .confirmationDialog(
            String(localized: "Remove \(original?.name ?? "")?"),
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Remove Source"), role: .destructive) { remove() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Its channels and movies leave every profile. Favorites and watch progress are kept, so adding it back brings them back.")
        }
    }

    private static let playlistTypes: [UTType] = [.m3uPlaylist, .plainText, .data]

    @ViewBuilder
    private var kindSection: some View {
        Section {
            if isNew {
                SegmentedPills(
                    String(localized: "Source type"),
                    options: SourceKind.allCases,
                    selection: Binding(get: { draft.kind }, set: { draft.changeKind(to: $0) })
                ) { kind in
                    switch kind {
                    case .stalker: String(localized: "Portal")
                    case .xtream: String(localized: "Xtream")
                    case .m3u: String(localized: "M3U")
                    }
                }
                // The pills draw their own track: they sit on the screen,
                // not on a row.
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } else {
                LabeledContent(String(localized: "Type"), value: SourceRowText.kindTitle(draft.kind))
                    .listRowBackground(HearthColor.surface)
            }
        } footer: {
            Text(Self.kindExplanation(draft.kind))
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
    }

    private static func kindExplanation(_ kind: SourceKind) -> String {
        switch kind {
        case .stalker: String(localized: "A Stalker (MAG) portal: its address and the MAC address your provider registered.")
        case .xtream: String(localized: "An Xtream Codes login: the server, username and password your provider sent.")
        case .m3u: String(localized: "An M3U playlist by link or file, with an XMLTV guide if the playlist doesn't name one.")
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            SourceField(String(localized: "Name"), text: $draft.name, prompt: draft.suggestedName)
            switch draft.kind {
            case .stalker:
                SourceField(String(localized: "Portal URL"), text: $draft.serverURL, prompt: "http://portal.example.com/c/", style: .url, problem: draft.problem(with: .serverURL))
                SourceField(String(localized: "MAC address"), text: $draft.macAddress, prompt: MACAddress.example, style: .code, problem: draft.problem(with: .macAddress), isConfirmed: MACAddress.isValid(draft.macAddress))
            case .xtream:
                SourceField(String(localized: "Server URL"), text: $draft.serverURL, prompt: "http://provider.example.com:8080", style: .url, problem: draft.problem(with: .serverURL))
                SourceField(String(localized: "Username"), text: $draft.username, prompt: "", style: .code)
                SourceField(String(localized: "Password"), text: $draft.password, prompt: "", style: .secure)
                SourceField(String(localized: "Guide URL (optional)"), text: $draft.guideURL, prompt: String(localized: "Uses the provider's guide"), style: .url, problem: draft.problem(with: .guideURL))
            case .m3u:
                playlistField
                SourceField(String(localized: "Guide URL (optional)"), text: $draft.guideURL, prompt: String(localized: "From the playlist's header"), style: .url, problem: draft.problem(with: .guideURL))
            }
        } header: {
            SectionLabel(String(localized: "Details"), style: .card)
        } footer: {
            if draft.kind == .m3u, draft.playlistURL.lowercased().hasPrefix("file:") {
                Text("A playlist file stays on this device. The household's other devices need a link to the same playlist.")
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
            }
        }
        .listRowBackground(HearthColor.surface)
    }

    private var playlistField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.playlistURL.lowercased().hasPrefix("file:") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Playlist")
                        .font(.hearthCaption)
                        .foregroundStyle(HearthColor.textSecondary)
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(HearthColor.accent)
                            .accessibilityHidden(true)
                        Text(URL(string: draft.playlistURL)?.lastPathComponent ?? draft.playlistURL)
                            .font(.hearthBody)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        // Borderless: a default-style button in a form row
                        // makes the whole row its target on iOS.
                        Button(String(localized: "Use a Link")) { draft.playlistURL = "" }
                            .buttonStyle(.borderless)
                            .font(.hearthFootnote)
                    }
                    .frame(minHeight: HearthMetrics.minimumHitTarget)
                }
            } else {
                SourceField(String(localized: "Playlist URL"), text: $draft.playlistURL, prompt: "https://provider.example.com/playlist.m3u", style: .url, problem: draft.problem(with: .playlistURL))
            }
            Button {
                isImportingFile = true
            } label: {
                HStack(spacing: 6) {
                    if isCopyingFile {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "folder").accessibilityHidden(true)
                    }
                    Text("Choose a playlist file…")
                }
                .font(.hearthText(14, weight: .medium, relativeTo: .callout))
                .foregroundStyle(HearthColor.accent)
                .frame(minHeight: HearthMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hearthTile)
            .disabled(isCopyingFile)
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                SourceField(String(localized: "Serial number"), text: $draft.serialNumber, prompt: String(localized: "Made from the MAC"), style: .code)
                SourceField(String(localized: "Device ID"), text: $draft.deviceID, prompt: String(localized: "Made from the MAC"), style: .code)
                SourceField(String(localized: "Device ID 2"), text: $draft.deviceID2, prompt: String(localized: "Same as device ID"), style: .code)
                SourceField(String(localized: "Signature"), text: $draft.signature, prompt: String(localized: "Made from the MAC"), style: .code)
                SourceField(String(localized: "Box model"), text: $draft.model, prompt: "MAG254", style: .code)
                SourceField(String(localized: "Time zone"), text: $draft.timeZone, prompt: TimeZone.current.identifier, style: .code, problem: draft.problem(with: .timeZone))
                SourceField(String(localized: "Username"), text: $draft.username, prompt: String(localized: "Only for portals that ask"), style: .code)
                SourceField(String(localized: "Password"), text: $draft.password, prompt: String(localized: "Only for portals that ask"), style: .secure)
            } label: {
                Text("Advanced")
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textPrimary)
                    .frame(minHeight: HearthMetrics.minimumHitTarget)
            }
        } footer: {
            Text("Only if your provider gave you these. Empty fields use what a MAG box would send.")
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
        .listRowBackground(HearthColor.surface)
    }

    @ViewBuilder
    private var streamsSection: some View {
        Section {
            if draft.kind == .xtream {
                LabeledContent(String(localized: "Streams allowed at once")) {
                    Text(xtreamLimitText)
                        .foregroundStyle(HearthColor.textSecondary)
                }
                .frame(minHeight: HearthMetrics.minimumHitTarget)
            } else {
                Stepper(value: $draft.maxStreams, in: 0...20) {
                    HStack {
                        Text("Streams allowed at once")
                        Spacer(minLength: 8)
                        Text(draft.maxStreams == 0 ? String(localized: "No limit") : "\(draft.maxStreams)")
                            .font(.hearthMono(15, relativeTo: .body))
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                }
                .frame(minHeight: HearthMetrics.minimumHitTarget)
                .accessibilityValue(Text(draft.maxStreams == 0 ? String(localized: "No limit") : "\(draft.maxStreams)"))
            }
        } footer: {
            Text(streamsFootnote)
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
        .listRowBackground(HearthColor.surface)
    }

    private var xtreamLimitText: String {
        let fromTest: Int? = if case .finished(let result, _) = test { result.account?.maxConnections } else { nil }
        let known = fromTest ?? original.flatMap { catalog.account(sourceID: $0.id)?.maxConnections }
        guard let known, known > 0 else { return String(localized: "Read from the provider") }
        return "\(known)"
    }

    private var streamsFootnote: String {
        switch draft.kind {
        case .stalker: String(localized: "Most portals allow one stream per MAC address. Before a play would go over, Hearth says who's watching.")
        case .xtream: String(localized: "Xtream reports its own limit and how many streams are in use.")
        case .m3u: String(localized: "0 means no limit. Set it if your provider allows only a few streams at once.")
        }
    }

    // MARK: Test (SRC-4)

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack(spacing: 8) {
                    if test == .running {
                        ProgressView().controlSize(.small).tint(HearthColor.textPrimary)
                        Text("Signing in…")
                    } else {
                        Image(systemName: "bolt.horizontal.circle").accessibilityHidden(true)
                        Text("Test connection")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hearthSecondary(shape: .rounded, size: .regular))
            .disabled(!draft.isComplete || test == .running || isCopyingFile)
            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            if case .finished(let result, _) = test {
                SourceTestResultCard(result: result, kind: draft.kind)
            }
        } footer: {
            Text(testFootnote)
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
        .listRowBackground(HearthColor.surface)
    }

    private var testFootnote: String {
        if draft.isComplete {
            return String(localized: "Signs in and counts what the provider offers, without saving anything.")
        }
        return String(localized: "Fill in the details above to test them.")
    }

    // MARK: Remove (SRC-9)

    @ViewBuilder
    private var removeSection: some View {
        Section {
            if original?.isRemoved == true {
                Button(String(localized: "Restore Source"), systemImage: "arrow.uturn.backward") {
                    restore()
                }
                .foregroundStyle(HearthColor.accent)
                .frame(minHeight: HearthMetrics.minimumHitTarget)
            } else {
                Button(String(localized: "Remove Source"), systemImage: "trash", role: .destructive) {
                    isConfirmingRemove = true
                }
                .foregroundStyle(HearthColor.danger)
                .frame(minHeight: HearthMetrics.minimumHitTarget)
            }
        } footer: {
            Text("Favorites and watch progress for this source are kept while it's removed.")
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
        .listRowBackground(HearthColor.surface)
    }

    private var lastRefreshFailure: String? {
        guard let id = original?.id, case .failed(let message) = catalog.refreshStates[id]?.phase else { return nil }
        return message
    }

    // MARK: Actions

    private func load() {
        guard !isLoaded else { return }
        if let sourceID {
            original = store.sources.first { $0.id == sourceID }
                ?? store.removedSources().first { $0.id == sourceID }
            if let original {
                draft = SourceDraft(record: original)
                draftID = original.id
                showsAdvanced = draft.kind == .stalker && draft.hasAdvancedValues
            }
        }
        initialDraft = draft
        isLoaded = true
    }

    private func runTest() {
        let configuration = draft.configuration(id: draftID)
        test = .running
        testTask?.cancel()
        testTask = Task {
            let result = await catalog.testSource(configuration)
            guard !Task.isCancelled else { return }
            test = .finished(result, configuration)
        }
    }

    private func importPlaylist(_ picked: URL) {
        isCopyingFile = true
        let id = draftID
        Task {
            defer { isCopyingFile = false }
            do {
                let copy = try await PlaylistFile.importCopy(of: picked, sourceID: id)
                draft.playlistURL = copy.absoluteString
                if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    draft.name = picked.deletingPathExtension().lastPathComponent
                }
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    /// Writes the record (login and all) to the household, then has the
    /// catalog download it once the app has handed the catalog the new
    /// sources (`RefreshAfterSave`).
    private func save() {
        guard draft.isComplete else { return }
        let configuration = draft.configuration(id: draftID)
        let account: AccountInfo? = if case .finished(let result, let tested) = test, result.succeeded,
            !SourceMapping.connectionChanged(tested, configuration) { result.account } else { nil }
        let maxStreams = draft.kind == .xtream
            ? (account?.maxConnections ?? original?.maxStreams ?? 1)
            : draft.maxStreams
        let record = SourceMapping.record(from: configuration, base: original, maxStreams: maxStreams, expiresAt: account?.expiresAt)
        let previousInCatalog = catalog.sources.first { $0.id == configuration.id }
        let errorBefore = store.lastWriteError

        if original == nil {
            store.addSource(record)
            guard store.sources.contains(where: { $0.id == record.id }) else {
                saveError = store.lastWriteError ?? String(localized: "The household didn't take the change. Check that you can still manage it.")
                return
            }
        } else {
            store.updateSource(record)
            if let error = store.lastWriteError, error != errorBefore {
                saveError = error
                return
            }
        }

        let oldConfiguration = original.map(SourceMapping.configuration(from:))
        if !record.isRemoved, SourceMapping.connectionChanged(oldConfiguration, configuration) {
            RefreshAfterSave.schedule(catalog: catalog, expected: configuration, previous: previousInCatalog)
        }
        initialDraft = draft
        dismiss()
    }

    private func remove() {
        guard let original else { return }
        catalog.cancelRefresh(sourceID: original.id)
        store.removeSource(id: original.id)
        initialDraft = draft
        dismiss()
    }

    private func restore() {
        guard let original else { return }
        store.restoreSource(id: original.id)
        initialDraft = draft
        dismiss()
    }
}

/// `SourceEditorView` for a sheet: its own navigation, Cancel (asking before
/// throwing away typing is left to the swipe being disabled), and a size that
/// suits a Mac sheet.
public struct SourceEditorSheet: View {
    let sourceID: UUID?
    @Environment(\.dismiss) private var dismiss

    public init(sourceID: UUID?) {
        self.sourceID = sourceID
    }

    public var body: some View {
        NavigationStack {
            SourceEditorView(sourceID: sourceID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { dismiss() }
                    }
                }
        }
        .interactiveDismissDisabled()
        .frame(minWidth: 460, idealWidth: 540, minHeight: 560, idealHeight: 680)
    }
}

/// After a save, refreshes the source's catalog once the app has passed the
/// saved login to `CatalogService.setSources` (the app shell maps
/// `store.sources` whenever it changes). Refreshing before that would sign in
/// with the old login, or not find a new source at all. It waits, briefly,
/// for the catalog's copy to change; if the app never maps it, nothing runs
/// (a new source is still imported by `setSources` itself, SRC-6).
@MainActor
enum RefreshAfterSave {
    static let wait: Duration = .seconds(15)

    static func schedule(catalog: CatalogService, expected: SourceConfiguration, previous: SourceConfiguration?) {
        Task { @MainActor in
            let deadline = ContinuousClock.now + wait
            var mapped = false
            while ContinuousClock.now < deadline {
                let current = catalog.sources.first { $0.id == expected.id }
                if let current, current == expected || current != previous {
                    mapped = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard mapped else { return }
            await catalog.refresh(sourceID: expected.id, force: true)
        }
    }
}
