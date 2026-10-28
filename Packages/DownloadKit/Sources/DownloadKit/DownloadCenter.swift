import Foundation
import Observation

/// Movies and episodes saved on this device (DL-1), as an environment
/// object. The app starts a download with a fresh link (`start`), shows
/// `records`, plays `localFile(for:)` instead of asking the provider, and
/// hears every change of state through `onChange` to keep a who's-watching
/// row while one runs (DL-2).
///
/// Records live in a JSON file in Application Support/Downloads; files the
/// app downloads sit beside it, and HLS packages where AVFoundation puts
/// them. Nothing here syncs: another device has downloads of its own.
@MainActor
@Observable
public final class DownloadCenter {
    /// iPhone, iPad and Mac. The Apple TV has no HLS downloads (and little
    /// storage to keep them in), so it offers none.
    public nonisolated static var isSupported: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    /// Newest first.
    public private(set) var records: [DownloadRecord] = []

    /// Every change of a record's state (not its progress), and a removal
    /// (the record as it was, `state` unchanged, with `isRemoved`).
    @ObservationIgnored public var onChange: ((DownloadRecord, _ isRemoved: Bool) -> Void)?

    @ObservationIgnored let folder: URL
    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let engine: (any DownloadEngine)?
    /// The last fraction written to disk per record, so progress is saved
    /// every few percent rather than on every callback.
    @ObservationIgnored private var savedFraction: [String: Double] = [:]

    /// The app's downloads, in Application Support/Downloads.
    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = support.appendingPathComponent("Downloads", isDirectory: true)
        #if os(tvOS)
        self.init(folder: folder, engine: nil)
        #else
        self.init(folder: folder, engine: SystemDownloadEngine(folder: folder))
        #endif
    }

    init(folder: URL, engine: (any DownloadEngine)?) {
        self.folder = folder
        self.store = DownloadStore(folder: folder)
        self.engine = engine
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        records = store.load().sorted { $0.createdAt > $1.createdAt }
        engine?.events = { [weak self] event in self?.handle(event) }
    }

    /// After launch: a download the system no longer holds (the app was
    /// quit while it ran) is paused, to be started again from a fresh link.
    /// A finished one whose file is gone is forgotten.
    public func reconcile() async {
        let alive = await engine?.restore() ?? []
        for record in records {
            switch record.state {
            case .running where !alive.contains(record.id):
                update(record.id) { $0.state = .paused }
            case .finished where localFile(for: record.id) == nil:
                forget(record.id)
            default:
                break
            }
        }
    }

    // MARK: Reading

    public func record(for itemKey: String) -> DownloadRecord? {
        records.first { $0.id == itemKey }
    }

    /// The finished download's file, when it's on disk: what the player
    /// opens instead of asking the provider.
    public func localFile(for itemKey: String) -> URL? {
        guard let record = record(for: itemKey), record.state == .finished, let location = record.location else { return nil }
        let url = DownloadFiles.url(of: location, folder: folder)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Running downloads take a stream each (DL-2).
    public var running: [DownloadRecord] { records.filter { $0.state == .running } }

    /// What the finished downloads take on disk.
    public var bytesOnDisk: Int64 {
        records.filter { $0.state == .finished }.reduce(0) { $0 + $1.bytesWritten }
    }

    // MARK: Changing

    /// Starts (or starts again) a download from a fresh link. A finished one
    /// is left alone.
    public func start(_ request: DownloadRequest, link: DownloadLink, profileID: UUID?) {
        guard let engine, record(for: request.itemKey)?.state != .finished else { return }
        engine.cancel(id: request.itemKey)
        removeFile(of: request.itemKey)
        let record = DownloadRecord(request: request, profileID: profileID, isHLS: link.isHLS)
        records.removeAll { $0.id == request.itemKey }
        records.insert(record, at: 0)
        savedFraction[record.id] = 0
        save()
        onChange?(record, false)
        engine.start(id: record.id, link: link, title: request.title)
    }

    public func pause(_ itemKey: String) {
        guard record(for: itemKey)?.state == .running else { return }
        _ = engine?.suspend(id: itemKey)
        update(itemKey) { $0.state = .paused }
    }

    /// Carries on a paused download whose task is still alive. False when it
    /// has to start over from a fresh link (`start`), as after a relaunch.
    @discardableResult
    public func resume(_ itemKey: String) -> Bool {
        guard record(for: itemKey)?.state == .paused, engine?.resume(id: itemKey) == true else { return false }
        update(itemKey) {
            $0.state = .running
            $0.failureMessage = nil
        }
        return true
    }

    /// Stops it if it's running and deletes what's on disk.
    public func remove(_ itemKey: String) {
        guard let record = record(for: itemKey) else { return }
        engine?.cancel(id: itemKey)
        removeFile(of: itemKey)
        records.removeAll { $0.id == itemKey }
        savedFraction[itemKey] = nil
        save()
        onChange?(record, true)
    }

    // MARK: Events

    func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let id, let written, let expected, let fraction):
            guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == .running else { return }
            if let written { records[index].bytesWritten = written }
            if let expected, expected > 0 { records[index].bytesExpected = expected }
            let computed = fraction ?? expected.flatMap { $0 > 0 ? Double(written ?? 0) / Double($0) : nil }
            if let computed { records[index].fraction = min(max(computed, 0), 1) }
            if records[index].fraction - (savedFraction[id] ?? 0) >= 0.05 {
                savedFraction[id] = records[index].fraction
                save()
            }
        case .finished(let id, let location):
            guard record(for: id) != nil else { return }
            let size = DownloadFiles.size(of: DownloadFiles.url(of: location, folder: folder))
            update(id) {
                $0.state = .finished
                $0.location = location
                $0.fraction = 1
                $0.failureMessage = nil
                if size > 0 { $0.bytesWritten = size }
                $0.finishedAt = .now
            }
        case .failed(let id, let message):
            guard record(for: id) != nil else { return }
            update(id) {
                $0.state = .failed
                $0.failureMessage = message
            }
        }
    }

    // MARK: Internals

    /// Applies a change, saves, and reports a change of state.
    private func update(_ id: String, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let before = records[index].state
        change(&records[index])
        save()
        if records[index].state != before { onChange?(records[index], false) }
    }

    private func forget(_ id: String) {
        guard let record = record(for: id) else { return }
        records.removeAll { $0.id == id }
        save()
        onChange?(record, true)
    }

    private func removeFile(of id: String) {
        guard let location = record(for: id)?.location else { return }
        try? FileManager.default.removeItem(at: DownloadFiles.url(of: location, folder: folder))
    }

    private func save() {
        store.save(records)
    }
}
