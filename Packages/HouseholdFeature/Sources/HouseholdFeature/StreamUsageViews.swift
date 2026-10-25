import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI

/// One source's streams right now (HH-5): its limit, how many are taken and
/// by whom. Built from the household's who's-watching rows and, for Xtream,
/// the provider's own count.
struct SourceStreamRow: Identifiable, Hashable {
    var id: UUID
    var name: String
    var usage: StreamBarUsage
    /// Fresh who's-watching rows on this source, oldest first.
    var playbacks: [PlaybackRecord]

    static func rows(sources: [SourceRecord], playbacks: [PlaybackRecord], account: (UUID) -> AccountInfo?, now: Date = .now) -> [SourceStreamRow] {
        sources.map { source in
            let mine = playbacks
                .filter { $0.sourceID == source.id && !$0.isStale(at: now) }
                .sorted { $0.startedAt < $1.startedAt }
            let account = account(source.id)
            return SourceStreamRow(
                id: source.id,
                name: source.name,
                usage: StreamBarUsage(
                    inUse: StreamLimit.inUse(for: source, account: account, playbacks: mine.count),
                    limit: StreamLimit.limit(for: source, account: account)
                ),
                playbacks: mine
            )
        }
    }
}

/// "STREAMS RIGHT NOW" on Household: a bar per source with who is watching
/// what where ("Anya · Living Room iPad · Lantern Drama").
struct StreamsRightNowSection: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(CatalogService.self) private var catalog

    var body: some View {
        let rows = SourceStreamRow.rows(sources: store.sources, playbacks: store.activePlaybacks, account: catalog.account(sourceID:))
        if !rows.isEmpty {
            GroupedCard(title: String(localized: "Streams right now"), rowPadding: 15) {
                ForEach(rows) { row in
                    StreamBar(row.name, usage: row.usage, caption: StreamCaption.lines(row.playbacks, profiles: store.profiles))
                }
            }
        }
    }
}

/// Each source's streams in use, as bars ("Provider B  2 of 2 · This device
/// and Anya's iPad"): the foot of the Mac sidebar (MAC-1). Draws nothing
/// while the household has no sources.
public struct StreamUsageSummaryView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(CatalogService.self) private var catalog

    public init() {}

    public var body: some View {
        let rows = SourceStreamRow.rows(sources: store.sources, playbacks: store.activePlaybacks, account: catalog.account(sourceID:))
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    StreamBar(
                        row.name,
                        usage: row.usage,
                        caption: StreamCaption.devices(row.playbacks, thisDevice: DeviceName.current),
                        size: .compact
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Streams in use"))
        }
    }
}
