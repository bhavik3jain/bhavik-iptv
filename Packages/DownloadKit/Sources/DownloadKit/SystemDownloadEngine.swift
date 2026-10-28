#if !os(tvOS)
import AVFoundation
import Foundation
import Synchronization

/// The system's background download sessions: HLS through
/// `AVAssetDownloadURLSession`, which saves a playable package, and
/// anything else as one file through `URLSession`. Background sessions keep
/// going while the app is suspended; tasks are found again after a relaunch
/// by their `taskDescription`, the record's id.
@MainActor
final class SystemDownloadEngine: DownloadEngine {
    var events: ((DownloadEvent) -> Void)? {
        didSet { relay.forward = { [weak self] event in Task { @MainActor in self?.events?(event) } } }
    }

    private let relay: SessionRelay
    private let fileSession: URLSession
    private let hlsSession: AVAssetDownloadURLSession
    private var tasks: [String: URLSessionTask] = [:]

    /// The system's `handleEventsForBackgroundURLSession` completion, kept
    /// until the session says it's done (iOS relaunches an app in the
    /// background to deliver finished downloads).
    nonisolated static let backgroundCompletions = Mutex<[String: @Sendable () -> Void]>([:])

    init(folder: URL, identifierPrefix: String = Bundle.main.bundleIdentifier ?? "hearth") {
        let relay = SessionRelay(folder: folder)
        self.relay = relay
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let files = URLSessionConfiguration.background(withIdentifier: identifierPrefix + ".downloads.files")
        files.sessionSendsLaunchEvents = true
        fileSession = URLSession(configuration: files, delegate: relay, delegateQueue: queue)
        let hls = URLSessionConfiguration.background(withIdentifier: identifierPrefix + ".downloads.hls")
        hls.sessionSendsLaunchEvents = true
        hlsSession = AVAssetDownloadURLSession(configuration: hls, assetDownloadDelegate: relay, delegateQueue: queue)
    }

    func start(id: String, link: DownloadLink, title: String) {
        let task: URLSessionTask
        if link.isHLS {
            var options: [String: Any] = [:]
            if !link.headers.isEmpty {
                // The same documented-but-private key the player uses: AVFoundation
                // has no public API for request headers.
                options["AVURLAssetHTTPHeaderFieldsKey"] = link.headers
            }
            let asset = AVURLAsset(url: link.url, options: options)
            task = hlsSession.makeAssetDownloadTask(downloadConfiguration: AVAssetDownloadConfiguration(asset: asset, title: title))
        } else {
            var request = URLRequest(url: link.url)
            for (name, value) in link.headers { request.setValue(value, forHTTPHeaderField: name) }
            task = fileSession.downloadTask(with: request)
        }
        task.taskDescription = id
        tasks[id] = task
        relay.watch(task)
        task.resume()
    }

    func suspend(id: String) -> Bool {
        guard let task = tasks[id], task.state == .running else { return false }
        task.suspend()
        return true
    }

    func resume(id: String) -> Bool {
        guard let task = tasks[id], task.state == .suspended else { return false }
        task.resume()
        return true
    }

    func cancel(id: String) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    func restore() async -> Set<String> {
        let found = await fileSession.allTasks + hlsSession.allTasks
        var ids: Set<String> = []
        for task in found where task.state == .running || task.state == .suspended {
            guard let id = task.taskDescription else { continue }
            tasks[id] = task
            relay.watch(task)
            ids.insert(id)
        }
        return ids
    }

    /// Called by the app's delegate with the system's completion handler.
    nonisolated static func handleEvents(forBackgroundSession identifier: String, completion: @escaping @Sendable () -> Void) {
        backgroundCompletions.withLock { $0[identifier] = completion }
    }
}

/// Both sessions' delegate. Called on the sessions' serial queue: a file
/// must be moved before `didFinishDownloadingTo` returns, so that happens
/// here, and everything else is forwarded to the engine on the main actor.
private final class SessionRelay: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate, Sendable {
    let folder: URL
    private let state = Mutex<State>(State())

    private struct State {
        var forward: (@Sendable (DownloadEvent) -> Void)?
        /// HLS packages by task, known before the task completes; finished
        /// only if it completes without an error.
        var packages: [Int: URL] = [:]
        /// Files already moved into place, waiting for the task to complete.
        var files: [Int: String] = [:]
        var observations: [Int: NSKeyValueObservation] = [:]
    }

    init(folder: URL) {
        self.folder = folder
    }

    var forward: (@Sendable (DownloadEvent) -> Void)? {
        get { state.withLock { $0.forward } }
        set { state.withLock { $0.forward = newValue } }
    }

    private func send(_ event: DownloadEvent) {
        forward?(event)
    }

    /// HLS reports progress through the task's `Progress`, not bytes.
    func watch(_ task: URLSessionTask) {
        guard task is AVAssetDownloadTask, let id = task.taskDescription else { return }
        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            self?.send(.progress(id: id, written: nil, expected: nil, fraction: progress.fractionCompleted))
        }
        state.withLock { $0.observations[task.taskIdentifier] = observation }
    }

    // MARK: Files

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        send(.progress(id: id, written: totalBytesWritten, expected: expected, fraction: nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            send(.failed(id: id, message: "The provider answered \(http.statusCode)."))
            return
        }
        let ext = DownloadFiles.fileExtension(url: downloadTask.originalRequest?.url, suggestedFilename: downloadTask.response?.suggestedFilename)
        let name = DownloadFiles.safeName(id) + "." + ext
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            // The file stays out of iCloud and device backups: the provider
            // has it, and it can be downloaded again.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = destination
            try? url.setResourceValues(values)
            state.withLock { $0.files[downloadTask.taskIdentifier] = name }
        } catch {
            send(.failed(id: id, message: error.localizedDescription))
        }
    }

    // MARK: HLS

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        state.withLock { $0.packages[assetDownloadTask.taskIdentifier] = location }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        state.withLock { $0.packages[assetDownloadTask.taskIdentifier] = location }
    }

    // MARK: Both

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (package, file) = state.withLock { state in
            state.observations.removeValue(forKey: task.taskIdentifier)?.invalidate()
            return (state.packages.removeValue(forKey: task.taskIdentifier), state.files.removeValue(forKey: task.taskIdentifier))
        }
        guard let id = task.taskDescription else { return }
        if let error {
            // Removing or replacing a download cancels its task; nothing to report.
            if (error as NSError).code == NSURLErrorCancelled {
                if let package { try? FileManager.default.removeItem(at: package) }
                return
            }
            if let package { try? FileManager.default.removeItem(at: package) }
            send(.failed(id: id, message: error.localizedDescription))
            return
        }
        if let package {
            send(.finished(id: id, location: .home(package.relativePath)))
        } else if let file {
            send(.finished(id: id, location: .downloadsFolder(file)))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        let completion = SystemDownloadEngine.backgroundCompletions.withLock { $0.removeValue(forKey: identifier) }
        if let completion { DispatchQueue.main.async { completion() } }
    }
}
#endif

extension DownloadCenter {
    /// For the app's delegate: iOS relaunches the app in the background to
    /// hand over finished downloads, with a handler to call once they're in.
    public nonisolated static func handleEvents(forBackgroundSession identifier: String, completion: @escaping @Sendable () -> Void) {
        #if os(tvOS)
        completion()
        #else
        SystemDownloadEngine.handleEvents(forBackgroundSession: identifier, completion: completion)
        #endif
    }
}
