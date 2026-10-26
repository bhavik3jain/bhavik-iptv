import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI

/// PAR-1's "plus any the owner marks": every category of every source, the
/// ones matched by name ("adult", "XXX", "18+") already counted, and a switch
/// for the rest. The marks belong to the household and sync through iCloud;
/// Sync's "Hide adult categories on every profile" decides whether they are
/// hidden for everyone or only on Kids profiles. Owner and managers only.
///
/// Shown in a sheet from the Sync section (`AdultCategoriesSheet`), so it
/// needs no route of its own.
struct AdultCategoriesView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(CatalogService.self) private var catalog

    @State private var kind: ContentKind = .live
    @State private var query = ""

    var body: some View {
        // Re-read when a refresh brings new categories or another device
        // marks one.
        let _ = (catalog.revision, store.revision)
        let list = AdultCategoryList(
            categories: catalog.categories(kind: kind, applyingFilter: false),
            marked: store.household.adultCategoryKeys,
            sourceNames: Dictionary(store.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            query: query
        )
        Form {
            Section {
                SegmentedPills(String(localized: "Kind of category"), options: ContentKind.allCases, selection: $kind) { kind in
                    AdultCategoryList.kindTitle(kind)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text(footnote)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
            }
            if list.groups.isEmpty {
                Section {
                    Text(list.isFiltered ? String(localized: "No categories match.") : String(localized: "No categories yet. They appear once a source has downloaded on this device."))
                        .font(.hearthBody)
                        .foregroundStyle(HearthColor.textSecondary)
                        .frame(minHeight: HearthMetrics.minimumHitTarget)
                }
                .listRowBackground(HearthColor.surface)
            }
            ForEach(list.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        categoryRow(row)
                    }
                } header: {
                    SectionLabel(group.title, style: .card)
                }
                .listRowBackground(HearthColor.surface)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(.hearthBody)
        .tint(HearthColor.accent)
        .searchable(text: $query, prompt: Text("Search categories"))
        .navigationTitle(Text("Adult Categories"))
        .inlineNavigationTitle()
        .hearthScreenBackground()
    }

    private var footnote: String {
        store.household.hidesAdultEverywhere
            ? String(localized: "Marked categories are hidden on every profile, like those matched by name.")
            : String(localized: "Marked categories are hidden on Kids profiles. Turn on \u{201C}Hide adult categories on every profile\u{201D} to hide them everywhere.")
    }

    @ViewBuilder
    private func categoryRow(_ row: AdultCategoryList.Row) -> some View {
        if row.isMatchedByName {
            // Always adult: the name says so, and a switch here couldn't
            // change it.
            LabeledContent {
                Text("Matched by name")
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
            } label: {
                Text(row.name)
                    .foregroundStyle(HearthColor.textPrimary)
            }
            .frame(minHeight: HearthMetrics.minimumHitTarget)
            .accessibilityElement(children: .combine)
        } else {
            Toggle(isOn: Binding(
                get: { row.isMarked },
                set: { setMarked(row.id, $0) }
            )) {
                Text(row.name)
                    .foregroundStyle(HearthColor.textPrimary)
            }
            .toggleStyle(.amber)
            .frame(minHeight: HearthMetrics.minimumHitTarget)
            .accessibilityHint(Text("Marks this category as adult"))
        }
    }

    /// One household write per switch: each wakes every household device.
    private func setMarked(_ categoryID: String, _ isMarked: Bool) {
        var keys = store.household.adultCategoryKeys
        if isMarked { keys.insert(categoryID) } else { keys.remove(categoryID) }
        guard keys != store.household.adultCategoryKeys else { return }
        store.setAdultCategoryKeys(keys)
    }
}

/// `AdultCategoriesView` in a sheet: its own navigation, Done, and a size
/// that suits a Mac sheet.
struct AdultCategoriesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AdultCategoriesView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 520, idealHeight: 680)
    }
}

/// The categories the adult-marking screen lists (PAR-1), grouped by source
/// in the catalog's order, narrowed by a search. A value type so the
/// grouping and matching are testable without the view.
struct AdultCategoryList: Hashable {
    struct Row: Identifiable, Hashable {
        /// The category key the household's marks and profile rules use.
        var id: String
        var name: String
        /// "adult", "XXX", "18+" in the name: adult whatever the marks say.
        var isMatchedByName: Bool
        var isMarked: Bool
    }

    struct Group: Identifiable, Hashable {
        var id: UUID
        var title: String
        var rows: [Row]
    }

    var groups: [Group]
    /// A search is narrowing the list.
    var isFiltered: Bool

    init(categories: [CatalogCategory], marked: Set<String>, sourceNames: [UUID: String], query: String) {
        let tokens = SearchKey.tokens(query)
        isFiltered = !tokens.isEmpty
        var order: [UUID] = []
        var rowsBySource: [UUID: [Row]] = [:]
        for category in categories {
            if !tokens.isEmpty {
                let name = SearchKey.normalize(category.name)
                guard tokens.allSatisfy({ name.contains($0) }) else { continue }
            }
            if rowsBySource[category.sourceID] == nil { order.append(category.sourceID) }
            rowsBySource[category.sourceID, default: []].append(Row(
                id: category.id,
                name: category.name.isEmpty ? String(localized: "Untitled category") : category.name,
                isMatchedByName: AdultContent.matches(category.name),
                isMarked: marked.contains(category.id)
            ))
        }
        groups = order.map { sourceID in
            Group(
                id: sourceID,
                title: sourceNames[sourceID] ?? String(localized: "Source"),
                rows: rowsBySource[sourceID] ?? []
            )
        }
    }

    static func kindTitle(_ kind: ContentKind) -> String {
        switch kind {
        case .live: String(localized: "Live TV")
        case .vod: String(localized: "Movies")
        case .series: String(localized: "Shows")
        }
    }
}
