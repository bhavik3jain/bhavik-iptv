import Foundation

/// What the system's download tasks report, by record id.
enum DownloadEvent: Sendable, Equatable {
    case progress(id: String, written: Int64?, expected: Int64?, fraction: Double?)
    case finished(id: String, location: DownloadLocation)
    case failed(id: String, message: String)
}

/// The system's download sessions behind `DownloadCenter`; a fake in tests.
@MainActor
protocol DownloadEngine: AnyObject {
    /// Set by the center, which turns events into record changes.
    var events: ((DownloadEvent) -> Void)? { get set }
    func start(id: String, link: DownloadLink, title: String)
    /// False when there's no task to pause (it ended, or the app relaunched).
    func suspend(id: String) -> Bool
    /// False when there's no task to resume: the download has to start
    /// again from a fresh link.
    func resume(id: String) -> Bool
    func cancel(id: String)
    /// Ids of the tasks the system still holds from an earlier launch.
    func restore() async -> Set<String>
}
