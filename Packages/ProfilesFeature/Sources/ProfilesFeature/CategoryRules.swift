import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// The three kinds of category a provider sends, as the picker's segments.
enum CategoryTab: String, CaseIterable, Hashable {
    case live
    case movies
    case shows

    var title: String {
        switch self {
        case .live: String(localized: "Live TV", bundle: .module)
        case .movies: String(localized: "Movies", bundle: .module)
        case .shows: String(localized: "Shows", bundle: .module)
        }
    }
}

/// One source's categories, as one card of the picker.
struct CategoryGroup: Identifiable, Hashable {
    var id: UUID
    var sourceName: String
    var categories: [CatalogCategory]
}

/// Groups a kind's categories by source, in the household's source order,
/// for the Kids and hidden-category pickers (PRF-4, PRF-6).
enum CategoryGrouping {
    /// - Parameters:
    ///   - sources: The household's sources in order, with their names.
    ///   - query: Narrows to names containing it, ignoring case and accents.
    ///   - adultKeys: Categories the household marked adult by hand, on top
    ///     of the catalog's name match (`CatalogCategory.isAdult`).
    ///   - excludingAdult: The Kids list leaves adult categories out: they
    ///     never show on a Kids profile, so offering them would only mislead.
    static func groups(_ categories: [CatalogCategory], sources: [(id: UUID, name: String)], query: String, adultKeys: Set<String> = [], excludingAdult: Bool) -> [CategoryGroup] {
        let needle = SearchKey.normalize(query)
        let kept = categories.filter { category in
            if excludingAdult, isAdult(category, adultKeys: adultKeys) { return false }
            return needle.isEmpty || SearchKey.normalize(category.name).contains(needle)
        }
        let bySource = Dictionary(grouping: kept, by: \.sourceID)
        var groups: [CategoryGroup] = []
        var seen = Set<UUID>()
        for source in sources {
            seen.insert(source.id)
            guard let list = bySource[source.id], !list.isEmpty else { continue }
            groups.append(CategoryGroup(id: source.id, sourceName: source.name, categories: sorted(list)))
        }
        // Categories of a source the household no longer lists (removed, or
        // not synced here yet) still show, so a rule on them can be undone.
        for (sourceID, list) in bySource where !seen.contains(sourceID) {
            groups.append(CategoryGroup(
                id: sourceID,
                sourceName: String(localized: "Other source", bundle: .module),
                categories: sorted(list)
            ))
        }
        return groups
    }

    /// Adult by the catalog's name match or by the household's own list.
    static func isAdult(_ category: CatalogCategory, adultKeys: Set<String>) -> Bool {
        category.isAdult || adultKeys.contains(category.id)
    }

    private static func sorted(_ list: [CatalogCategory]) -> [CatalogCategory] {
        list.sorted { a, b in
            a.sortOrder != b.sortOrder ? a.sortOrder < b.sortOrder : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Picks categories for a profile, grouped by source: the categories a Kids
/// profile may see (PRF-4) or the ones a profile hides (PRF-6, LIV-8).
/// Reads the catalog unfiltered, since the rules being edited are the filter.
struct CategoryRulesView: View {
    enum Mode {
        case allowed
        case hidden
    }

    let mode: Mode
    @Binding var selection: Set<String>

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store

    @State private var tab = CategoryTab.live
    @State private var query = ""

    /// Above this many categories in a tab, a search field helps (Stalker
    /// portals often send a hundred or more live categories).
    private static let searchThreshold = 12

    var body: some View {
        let _ = catalog.revision
        let _ = store.revision
        let all = categories(for: tab)
        let groups = CategoryGrouping.groups(
            all, sources: sourceNames, query: query, adultKeys: store.household.adultCategoryKeys, excludingAdult: mode == .allowed
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text(introduction)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                SegmentedPills(String(localized: "Category type", bundle: .module), options: CategoryTab.allCases, selection: $tab) { tab in
                    let count = selectedCount(in: categories(for: tab))
                    return count == 0 ? tab.title : "\(tab.title) · \(count)"
                }
                if all.count > Self.searchThreshold {
                    SearchField(String(localized: "Search categories", bundle: .module), text: $query)
                }
                if groups.isEmpty {
                    emptyState(hasCategories: !all.isEmpty)
                } else {
                    ForEach(groups) { group in
                        GroupedCard(title: group.sourceName) {
                            selectAllRow(group)
                            ForEach(group.categories) { category in
                                categoryRow(category)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .hearthScreenBackground()
        .navigationTitle(mode == .allowed
                         ? String(localized: "Allowed categories", bundle: .module)
                         : String(localized: "Hidden categories", bundle: .module))
        .inlineNavigationTitle()
        .onChange(of: tab) { query = "" }
    }

    private var introduction: String {
        switch mode {
        case .allowed:
            String(localized: "Pick what this Kids profile can watch. Everything else stays out of sight, including categories a provider adds later.", bundle: .module)
        case .hidden:
            String(localized: "Hidden categories don’t show on this profile anywhere: not in Live TV, the library or search.", bundle: .module)
        }
    }

    private func categories(for tab: CategoryTab) -> [CatalogCategory] {
        switch tab {
        case .live: catalog.categories(kind: .live, applyingFilter: false)
        case .movies: catalog.categories(kind: .vod, applyingFilter: false)
        case .shows: catalog.categories(kind: .series, applyingFilter: false)
        }
    }

    private func selectedCount(in categories: [CatalogCategory]) -> Int {
        categories.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
    }

    /// The household's sources in order. A watcher's device has them too
    /// (names only matter here, never logins).
    private var sourceNames: [(id: UUID, name: String)] {
        store.sources.map { ($0.id, $0.name) }
    }

    // MARK: Rows

    private func selectAllRow(_ group: CategoryGroup) -> some View {
        let ids = group.categories.map(\.id)
        let allSelected = ids.allSatisfy(selection.contains)
        let title: String = switch (mode, allSelected) {
        case (.allowed, false): String(localized: "Allow all", bundle: .module)
        case (.allowed, true): String(localized: "Allow none", bundle: .module)
        case (.hidden, false): String(localized: "Hide all", bundle: .module)
        case (.hidden, true): String(localized: "Show all", bundle: .module)
        }
        return CardActionRow(title, systemImage: allSelected ? "xmark.circle" : "checkmark.circle") {
            if allSelected {
                selection.subtract(ids)
            } else {
                selection.formUnion(ids)
            }
        }
    }

    private func categoryRow(_ category: CatalogCategory) -> some View {
        let isOn = selection.contains(category.id)
        return Button {
            if isOn {
                selection.remove(category.id)
            } else {
                selection.insert(category.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(isOn: isOn))
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isOn ? onColor : HearthColor.glyphMuted)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(category.name)
                    .font(.hearthBody)
                    .foregroundStyle(isOn && mode == .hidden ? HearthColor.textSecondary : HearthColor.textPrimary)
                    .strikethrough(isOn && mode == .hidden, color: HearthColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if CategoryGrouping.isAdult(category, adultKeys: store.household.adultCategoryKeys) {
                    StatusChip(String(localized: "Adult", bundle: .module))
                }
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hearthTile)
        .accessibilityLabel(Text(category.name))
        .accessibilityValue(Text(stateText(isOn: isOn)))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func symbol(isOn: Bool) -> String {
        switch mode {
        case .allowed: isOn ? "checkmark.circle.fill" : "circle"
        case .hidden: isOn ? "eye.slash.fill" : "eye"
        }
    }

    private var onColor: Color {
        mode == .allowed ? HearthColor.accent : HearthColor.danger
    }

    private func stateText(isOn: Bool) -> String {
        switch mode {
        case .allowed: isOn ? String(localized: "Allowed", bundle: .module) : String(localized: "Not allowed", bundle: .module)
        case .hidden: isOn ? String(localized: "Hidden", bundle: .module) : String(localized: "Shown", bundle: .module)
        }
    }

    @ViewBuilder
    private func emptyState(hasCategories: Bool) -> some View {
        if hasCategories {
            EmptyStateView(
                systemName: "magnifyingglass",
                title: String(localized: "No matching categories", bundle: .module),
                message: mode == .allowed
                    ? String(localized: "Adult categories aren’t offered for Kids profiles.", bundle: .module)
                    : nil
            )
        } else {
            EmptyStateView(
                systemName: "square.stack.3d.up.slash",
                title: String(localized: "No categories yet", bundle: .module),
                message: String(localized: "Categories appear here once a source has finished loading on this device.", bundle: .module)
            )
        }
    }
}
