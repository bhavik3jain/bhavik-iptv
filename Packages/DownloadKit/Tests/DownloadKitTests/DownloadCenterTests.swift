import Foundation
import Testing
@testable import DownloadKit

/// The system's sessions, in memory: records what it was asked and reports
/// what a test tells it to.
@MainActor
final class FakeEngine: DownloadEngine {
    var events: ((DownloadEvent) -> Void)?
    var started: [(id: String, link: DownloadLink)] = []
    var suspended: Set<String> = []
    var cancelled: [String] = []
    var alive: Set<String> = []

    func start(id: String, link: DownloadLink, title: String) {
        started.append((id, link))
        alive.insert(id)
    }

    func suspend(id: String) -> Bool {
        guard alive.contains(id) else { return false }
        suspended.insert(id)
        return true
    }

    func resume(id: String) -> Bool {
        guard alive.contains(id), suspended.remove(id) != nil else { return false }
        return true
    }

    func cancel(id: String) {
        cancelled.append(id)
        alive.remove(id)
    }

    func restore() async -> Set<String> { alive }
}

@MainActor
@Suite struct DownloadCenterTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadKitTests-\(UUID().uuidString)", isDirectory: true)
    let source = UUID()
    let profile = UUID()

    func request(_ id: String = "S/movie/7101", title: String = "Paper Boats") -> DownloadRequest {
        DownloadRequest(itemKey: id, kind: .movie, title: title, sourceID: source)
    }

    let link = DownloadLink(url: URL(string: "http://vod.test/movie/index.m3u8?token=Tk1")!, headers: ["User-Agent": "MAG200"], isHLS: true)

    /// A file standing in for what the engine moved into the folder.
    func placeFile(_ name: String, bytes: Int = 1_000) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: folder.appendingPathComponent(name))
    }

    @Test func startRecordsAndRunsIt() throws {
        let engine = FakeEngine()
        let center = DownloadCenter(folder: folder, engine: engine)
        var changes: [DownloadState] = []
        center.onChange = { record, _ in changes.append(record.state) }

        center.start(request(), link: link, profileID: profile)
        let record = try #require(center.record(for: "S/movie/7101"))
        #expect(record.state == .running)
        #expect(record.isHLS)
        #expect(record.profileID == profile)
        #expect(engine.started.map(\.id) == ["S/movie/7101"])
        #expect(engine.started.first?.link.headers["User-Agent"] == "MAG200")
        #expect(center.running.count == 1)
        #expect(changes == [.running])
    }

    @Test func progressFromBytesOrFromTheFraction() {
        let engine = FakeEngine()
        let center = DownloadCenter(folder: folder, engine: engine)
        center.start(request(), link: link, profileID: profile)
        center.handle(.progress(id: "S/movie/7101", written: 250, expected: 1_000, fraction: nil))
        #expect(center.record(for: "S/movie/7101")?.fraction == 0.25)
        #expect(center.record(for: "S/movie/7101")?.bytesExpected == 1_000)
        center.handle(.progress(id: "S/movie/7101", written: nil, expected: nil, fraction: 0.6))
        #expect(center.record(for: "S/movie/7101")?.fraction == 0.6)
        // Never past the end.
        center.handle(.progress(id: "S/movie/7101", written: nil, expected: nil, fraction: 1.4))
        #expect(center.record(for: "S/movie/7101")?.fraction == 1)
    }

    @Test func finishingKeepsTheFileAndItsSize() throws {
        let engine = FakeEngine()
        let center = DownloadCenter(folder: folder, engine: engine)
        center.start(request(), link: DownloadLink(url: URL(string: "http://vod.test/7101.mkv")!, isHLS: false), profileID: profile)
        try placeFile("S_movie_7101.mkv", bytes: 4_096)
        center.handle(.finished(id: "S/movie/7101", location: .downloadsFolder("S_movie_7101.mkv")))

        let record = try #require(center.record(for: "S/movie/7101"))
        #expect(record.state == .finished)
        #expect(record.fraction == 1)
        #expect(record.bytesWritten == 4_096)
        #expect(record.finishedAt != nil)
        #expect(center.localFile(for: "S/movie/7101")?.lastPathComponent == "S_movie_7101.mkv")
        #expect(center.bytesOnDisk == 4_096)
        #expect(center.running.isEmpty)
    }

    @Test func pauseAndResumeWhileTheTaskLives() {
        let engine = FakeEngine()
        let center = DownloadCenter(folder: folder, engine: engine)
        center.start(request(), link: link, profileID: profile)
        center.pause("S/movie/7101")
        #expect(center.record(for: "S/movie/7101")?.state == .paused)
        #expect(center.running.isEmpty) // a paused download takes no stream
        #expect(center.resume("S/movie/7101"))
        #expect(center.record(for: "S/movie/7101")?.state == .running)
    }

    @Test func aDownloadLostInARelaunchIsPausedAndMustStartAgain() async {
        let engine = FakeEngine()
        let first = DownloadCenter(folder: folder, engine: engine)
        first.start(request(), link: link, profileID: profile)

        // The app quits; the system kept nothing.
        let second = DownloadCenter(folder: folder, engine: FakeEngine())
        #expect(second.record(for: "S/movie/7101")?.state == .running)
        await second.reconcile()
        #expect(second.record(for: "S/movie/7101")?.state == .paused)
        #expect(second.resume("S/movie/7101") == false)
    }

    @Test func aTaskTheSystemKeptCarriesOn() async {
        let engine = FakeEngine()
        let first = DownloadCenter(folder: folder, engine: engine)
        first.start(request(), link: link, profileID: profile)
        let second = DownloadCenter(folder: folder, engine: engine)
        await second.reconcile()
        #expect(second.record(for: "S/movie/7101")?.state == .running)
    }

    @Test func aFinishedDownloadWhoseFileIsGoneIsForgotten() async throws {
        let center = DownloadCenter(folder: folder, engine: FakeEngine())
        center.start(request(), link: link, profileID: profile)
        try placeFile("gone.mp4")
        center.handle(.finished(id: "S/movie/7101", location: .downloadsFolder("gone.mp4")))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("gone.mp4"))
        await center.reconcile()
        #expect(center.record(for: "S/movie/7101") == nil)
    }

    @Test func removeCancelsAndDeletesTheFile() throws {
        let engine = FakeEngine()
        let center = DownloadCenter(folder: folder, engine: engine)
        var removed: [String] = []
        center.onChange = { record, isRemoved in if isRemoved { removed.append(record.id) } }
        center.start(request(), link: link, profileID: profile)
        try placeFile("a.mp4")
        center.handle(.finished(id: "S/movie/7101", location: .downloadsFolder("a.mp4")))
        center.remove("S/movie/7101")
        #expect(center.records.isEmpty)
        #expect(engine.cancelled.contains("S/movie/7101"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.mp4").path))
        #expect(removed == ["S/movie/7101"])
    }

    @Test func aFailureIsKeptWithItsReason() {
        let center = DownloadCenter(folder: folder, engine: FakeEngine())
        center.start(request(), link: link, profileID: profile)
        center.handle(.failed(id: "S/movie/7101", message: "The provider answered 403."))
        #expect(center.record(for: "S/movie/7101")?.state == .failed)
        #expect(center.record(for: "S/movie/7101")?.failureMessage == "The provider answered 403.")
        // Starting again from a fresh link replaces it.
        center.start(request(), link: link, profileID: profile)
        #expect(center.record(for: "S/movie/7101")?.state == .running)
        #expect(center.record(for: "S/movie/7101")?.failureMessage == nil)
        #expect(center.records.count == 1)
    }

    @Test func aFinishedDownloadIsntStartedAgain() throws {
        let engine = FakeEngine()
        let center = DownloadCenter(folder: folder, engine: engine)
        center.start(request(), link: link, profileID: profile)
        try placeFile("a.mp4")
        center.handle(.finished(id: "S/movie/7101", location: .downloadsFolder("a.mp4")))
        center.start(request(), link: link, profileID: profile)
        #expect(engine.started.count == 1)
        #expect(center.record(for: "S/movie/7101")?.state == .finished)
    }

    @Test func recordsSurviveARelaunchNewestFirst() {
        let center = DownloadCenter(folder: folder, engine: FakeEngine())
        center.start(request("S/movie/1", title: "First"), link: link, profileID: profile)
        center.start(request("S/movie/2", title: "Second"), link: link, profileID: profile)
        let reopened = DownloadCenter(folder: folder, engine: FakeEngine())
        #expect(reopened.records.map(\.title) == ["Second", "First"])
    }

    @Test func fileNamesAndExtensions() {
        #expect(DownloadFiles.safeName("7E1C/movie/7101") == "7E1C_movie_7101")
        #expect(DownloadFiles.fileExtension(url: URL(string: "http://vod.test/a/7002.mkv?token=1"), suggestedFilename: nil) == "mkv")
        #expect(DownloadFiles.fileExtension(url: URL(string: "http://vod.test/play/movie.php?stream=1"), suggestedFilename: "1.mp4") == "mp4")
        #expect(DownloadFiles.fileExtension(url: URL(string: "http://vod.test/stream"), suggestedFilename: nil) == "mp4")
    }
}
