import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI

// The grouped sections under Household's first card (mockup 05). Each reads
// the services itself so the screen's body stays a list of sections.

// MARK: - Profiles

/// "PROFILES": each profile with what it may see, into its editor; Add
/// profile up to eight (PRF-1, HouseholdStore.maxProfiles).
struct ProfilesSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session

    var body: some View {
        let canManage = session.canManageHousehold
        let atLimit = store.profiles.count >= HouseholdStore.maxProfiles
        GroupedCard(
            title: String(localized: "Profiles"),
            footer: canManage && atLimit ? String(localized: "A household has up to \(HouseholdStore.maxProfiles) profiles.") : nil
        ) {
            ForEach(store.profiles) { profile in
                if canManage {
                    NavigationLink(value: HearthRoute.profileEditor(profileID: profile.id)) {
                        row(profile, opens: true)
                    }
                    .buttonStyle(.hearthTile)
                    .accessibilityHint(Text("Edit profile"))
                } else {
                    row(profile, opens: false)
                }
            }
            if canManage && !atLimit {
                NavigationLink(value: HearthRoute.profileEditor(profileID: nil)) {
                    AddRowLabel(String(localized: "Add profile"))
                }
                .buttonStyle(.hearthTile)
            }
        }
    }

    private func row(_ profile: ProfileRecord, opens: Bool) -> some View {
        CardRow(
            profile.name,
            subtitle: ProfileSummaryText.subtitle(for: profile, sourceCount: store.sources.count),
            showsChevron: opens
        ) {
            AvatarTile(name: profile.name, palette: profile.avatarColor, symbol: profile.avatarSymbol, size: 38, isLocked: profile.hasPIN)
        }
    }
}

// MARK: - Sources

/// "SOURCES" (SRC-5, SRC-8, SRC-9): each source with its kind, masked login
/// and status, refresh on demand, the editor for the owner and managers, and
/// the removed sources to bring back. A watcher sees names and status only.
struct SourcesSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(CatalogService.self) private var catalog
    @Environment(\.openRoute) private var openRoute

    @State private var showsRemoved = false
    @State private var sourceToRemove: SourceRecord?

    var body: some View {
        let canManage = session.canManageHousehold
        let removed = canManage ? removedSources : []
        VStack(alignment: .leading, spacing: 10) {
            header
            GroupedCard(footer: canManage
                ? String(localized: "Logins are shared with everyone in the household and kept encrypted in iCloud.")
                : String(localized: "Only the owner and managers can see or change logins.")
            ) {
                ForEach(store.sources) { source in
                    sourceRow(source, canManage: canManage)
                }
                if canManage {
                    NavigationLink(value: HearthRoute.sourceEditor(sourceID: nil)) {
                        AddRowLabel(String(localized: "Add a portal, Xtream login or playlist"))
                    }
                    .buttonStyle(.hearthTile)
                } else if store.sources.isEmpty {
                    CardRow(String(localized: "No sources yet"), subtitle: String(localized: "The owner or a manager adds them."))
                }
            }
            if !removed.isEmpty {
                removedCard(removed)
            }
        }
        .confirmationDialog(
            String(localized: "Remove \(sourceToRemove?.name ?? "")?"),
            isPresented: isShowing($sourceToRemove),
            titleVisibility: .visible,
            presenting: sourceToRemove
        ) { source in
            Button(String(localized: "Remove Source"), role: .destructive) {
                catalog.cancelRefresh(sourceID: source.id)
                store.removeSource(id: source.id)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Its channels and movies leave every profile. Favorites and watch progress are kept, so adding it back brings them back.")
        }
    }

    /// Removed sources, re-read when the store changes.
    private var removedSources: [SourceRecord] {
        _ = store.revision
        return store.removedSources()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionLabel(String(localized: "Sources"))
            Spacer(minLength: 8)
            if !store.sources.isEmpty {
                Button {
                    refreshAll()
                } label: {
                    Label(String(localized: "Refresh all"), systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(.hearthText(13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(HearthColor.accent)
                        .frame(minHeight: HearthMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hearthTile)
                .accessibilityHint(Text("Downloads every source's channels, movies and guide again on this device"))
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func sourceRow(_ source: SourceRecord, canManage: Bool) -> some View {
        let text = SourceRowText(record: source, state: catalog.refreshStates[source.id], canSeeLogins: canManage)
        let row = CardRow(text.title, subtitle: text.subtitle, minHeight: 68) {
            CardTile(text: text.code)
        } trailing: {
            SourceStatusLabel(text: text)
        }
        Group {
            if canManage {
                NavigationLink(value: HearthRoute.sourceEditor(sourceID: source.id)) { row }
                    .buttonStyle(.hearthTile)
                    .accessibilityHint(Text("Edit source"))
            } else {
                row
            }
        }
        .contextMenu {
            Button(String(localized: "Refresh Now"), systemImage: "arrow.clockwise") {
                refresh(source.id)
            }
            .disabled(text.isRefreshing)
            if canManage {
                Button(String(localized: "Edit"), systemImage: "pencil") {
                    openRoute(.sourceEditor(sourceID: source.id))
                }
                Button(String(localized: "Remove"), systemImage: "trash", role: .destructive) {
                    sourceToRemove = source
                }
            }
        }
        .accessibilityAction(named: Text("Refresh now")) { refresh(source.id) }
    }

    /// SRC-9: a source taken away keeps its favorites and progress; Restore
    /// brings them back with it.
    private func removedCard(_ removed: [SourceRecord]) -> some View {
        GroupedCard {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showsRemoved.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text("Removed sources")
                        .font(.hearthBody)
                        .foregroundStyle(HearthColor.textPrimary)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(removed.count)")
                        .font(.hearthMono(13, relativeTo: .footnote))
                        .foregroundStyle(HearthColor.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HearthColor.glyphMuted)
                        .rotationEffect(.degrees(showsRemoved ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hearthTile)
            .accessibilityValue(Text(showsRemoved ? String(localized: "Expanded") : String(localized: "Collapsed")))
            if showsRemoved {
                ForEach(removed) { source in
                    HStack(spacing: 12) {
                        CardTile(text: SourceRowText.code(for: SourceMapping.kind(of: source)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.hearthText(15, weight: .medium, relativeTo: .body))
                                .foregroundStyle(HearthColor.textPrimary)
                            Text("Favorites and progress kept")
                                .font(.hearthFootnote)
                                .foregroundStyle(HearthColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        Button(String(localized: "Restore")) {
                            store.restoreSource(id: source.id)
                        }
                        .buttonStyle(.hearthSecondary(shape: .capsule, size: .small))
                        .accessibilityLabel(Text("Restore \(source.name)"))
                    }
                    .frame(minHeight: 64)
                }
            }
        }
    }

    private func refresh(_ sourceID: UUID) {
        SourceRefresher.refresh([sourceID], in: catalog)
    }

    private func refreshAll() {
        SourceRefresher.refresh(store.sources.map(\.id), in: catalog)
    }
}

/// "Refresh now" for one source or all of them (SRC-6): a forced catalog
/// download, one source after another, on a task of its own so leaving the
/// screen doesn't cancel it (`CatalogService.refresh` stops an import whose
/// caller is cancelled). A source already updating is joined, not started
/// twice.
@MainActor
enum SourceRefresher {
    static func refresh(_ sourceIDs: [UUID], in catalog: CatalogService) {
        guard !sourceIDs.isEmpty else { return }
        Task { @MainActor in
            for id in sourceIDs {
                await catalog.refresh(sourceID: id, force: true)
            }
        }
    }
}

/// The right-hand status on a source row: grey normally, red when it needs
/// attention, with a spinner while it updates.
private struct SourceStatusLabel: View {
    let text: SourceRowText

    var body: some View {
        HStack(spacing: 6) {
            if text.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(HearthColor.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(text.status)
                .font(.hearthText(12, relativeTo: .caption))
                .foregroundStyle(text.isWarning ? HearthColor.danger : HearthColor.textSecondary)
                .multilineTextAlignment(.trailing)
                .fixedSize()
        }
    }
}

/// The amber "+ Add …" row at a card's foot, as a label for a
/// `NavigationLink` (Core's `CardActionRow` is a button).
struct AddRowLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(.hearthText(15, weight: .medium, relativeTo: .body))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(HearthColor.accent)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

// MARK: - Sync

/// "SYNC": the one household-wide switch that does something (PAR-1), the
/// categories marked adult by hand, and where things live. Favorites and
/// progress always sync per profile, so they get a sentence rather than
/// switches that change nothing.
struct SyncSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session

    @State private var isMarkingCategories = false

    var body: some View {
        let sync = SyncStatusText.text(store.syncStatus)
        let marked = store.household.adultCategoryKeys.count
        GroupedCard(title: String(localized: "Sync"), footer: footnote) {
            if session.canManageHousehold {
                CardToggleRow(
                    String(localized: "Hide adult categories on every profile"),
                    subtitle: String(localized: "Categories named adult, XXX or 18+, and any marked by hand"),
                    isOn: Binding(
                        get: { store.household.hidesAdultEverywhere },
                        set: { store.setHidesAdultEverywhere($0) }
                    )
                )
                Button {
                    isMarkingCategories = true
                } label: {
                    CardRow(
                        String(localized: "Mark adult categories"),
                        trailingText: marked == 0 ? String(localized: "None by hand") : String(localized: "\(marked) marked"),
                        showsChevron: true
                    )
                }
                .buttonStyle(.hearthTile)
                .accessibilityHint(Text("Lists every category so you can mark the ones a name doesn't give away"))
            } else {
                CardRow(
                    String(localized: "Adult categories"),
                    trailingText: store.household.hidesAdultEverywhere ? String(localized: "Hidden everywhere") : String(localized: "Hidden on Kids profiles")
                )
            }
            HStack(spacing: 12) {
                Text("iCloud")
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textPrimary)
                Spacer(minLength: 8)
                Text(sync.text)
                    .font(.hearthFootnote)
                    .foregroundStyle(sync.isWarning ? HearthColor.danger : HearthColor.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 48)
            .accessibilityElement(children: .combine)
        }
        .sheet(isPresented: $isMarkingCategories) {
            AdultCategoriesSheet()
        }
    }

    private var footnote: String {
        var text = String(localized: "Favorites, My List and watch progress sync for each profile through iCloud. Channel lists, posters and the guide download on each device.")
        if let error = store.lastWriteError {
            text += "\n" + String(localized: "The last change didn't save: \(error)")
        }
        return text
    }
}
