import CatalogKit
import Foundation

/// Programmes per channel, fetched from the catalog in six-hour blocks and
/// kept until the catalog changes.
///
/// The guide's rows ask this in their body, which runs when a row appears,
/// when the drawn window moves an hour, once a minute for the now line and
/// when the catalog's `revision` changes — never per scrolled frame. A row
/// coming back on screen reads its blocks from memory instead of the store,
/// so flicking through 1,000 channels costs one fetch per channel per block.
///
/// Not observable on purpose: it is a memo, not state. Views pass the
/// catalog revision in, and a new revision empties it.
@MainActor
final class GuideProgrammeCache {
    private struct BlockKey: Hashable {
        var channel: ItemKey
        var index: Int
    }

    static let blockLength: TimeInterval = 6 * 3600
    /// Re-read after this long even without a new revision: the catalog
    /// works out a programme's `hasArchive` when it reads it.
    static let maxAge: TimeInterval = 10 * 60
    /// About 1,000 channels × 4 blocks; past this the memo starts over.
    static let maxBlocks = 4_000

    private var revision: Int?
    private var filledAt = Date.distantPast
    private var blocks: [BlockKey: [CatalogProgramme]] = [:]
    private var nowNext: [ItemKey: (minute: Int, now: CatalogProgramme?, next: CatalogProgramme?)] = [:]

    /// The channel's programmes overlapping `window`, by start.
    func programmes(for channel: CatalogChannel, in window: GuideWindow, catalog: CatalogService, revision: Int, now: Date) -> [CatalogProgramme] {
        programmes(for: channel, from: window.start, to: window.end, catalog: catalog, revision: revision, now: now)
    }

    func programmes(for channel: CatalogChannel, from start: Date, to end: Date, catalog: CatalogService, revision: Int, now: Date) -> [CatalogProgramme] {
        guard start < end else { return [] }
        invalidateIfNeeded(revision: revision, now: now)
        let first = Int((start.timeIntervalSince1970 / Self.blockLength).rounded(.down))
        let last = Int(((end.timeIntervalSince1970 - 1) / Self.blockLength).rounded(.down))
        var seen = Set<String>()
        var result: [CatalogProgramme] = []
        for index in first...max(first, last) {
            let key = BlockKey(channel: channel.key, index: index)
            let block: [CatalogProgramme]
            if let cached = blocks[key] {
                block = cached
            } else {
                let blockStart = Date(timeIntervalSince1970: TimeInterval(index) * Self.blockLength)
                block = catalog.programmes(for: channel, from: blockStart, to: blockStart.addingTimeInterval(Self.blockLength))
                blocks[key] = block
            }
            // A programme crossing a block boundary is in both blocks.
            for programme in block where programme.end > start && programme.start < end && seen.insert(programme.id).inserted {
                result.append(programme)
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// What's on now and next, memoised for the minute.
    func nowAndNext(for channel: CatalogChannel, catalog: CatalogService, revision: Int, now: Date) -> (now: CatalogProgramme?, next: CatalogProgramme?) {
        invalidateIfNeeded(revision: revision, now: now)
        let minute = Int(now.timeIntervalSince1970 / 60)
        if let cached = nowNext[channel.key], cached.minute == minute {
            return (cached.now, cached.next)
        }
        let value = catalog.nowAndNext(for: channel, at: now)
        nowNext[channel.key] = (minute, value.now, value.next)
        return value
    }

    private func invalidateIfNeeded(revision: Int, now: Date) {
        if revision != self.revision || now.timeIntervalSince(filledAt) > Self.maxAge || filledAt > now || blocks.count > Self.maxBlocks {
            blocks.removeAll(keepingCapacity: true)
            nowNext.removeAll(keepingCapacity: true)
            self.revision = revision
            filledAt = now
        }
    }
}

/// Asks the catalog for the short guide of channels as they come on screen
/// (Stalker portals have no full guide, so each channel's next programmes
/// are fetched on demand). Rows report themselves as they appear; requests
/// are gathered for a moment and sent as one batch, so a fling past fifty
/// rows makes one call, not fifty. The catalog throttles each channel too.
@MainActor
final class ShortGuideRequests {
    private var pending: [ItemKey: CatalogChannel] = [:]
    private var task: Task<Void, Never>?

    func request(_ channel: CatalogChannel, catalog: CatalogService) {
        pending[channel.key] = channel
        guard task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let batch = Array(self.pending.values)
            self.pending.removeAll()
            self.task = nil
            guard !batch.isEmpty else { return }
            await catalog.loadShortGuide(for: batch)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending.removeAll()
    }
}
