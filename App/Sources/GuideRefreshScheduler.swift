import Foundation

#if os(iOS)
import BackgroundTasks
#endif

/// SRC-6's background half on iOS: a BGAppRefreshTask that refreshes stale
/// guides and catalogs every ~6 hours when the system allows. The Mac has no
/// background refresh; it refreshes at launch and on becoming active.
///
/// Two traps from Multitrack's TV refresh (technical spec, Refresh): the
/// task must be registered before launch finishes (so from `HearthApp.init`),
/// with its identifier listed in `BGTaskSchedulerPermittedIdentifiers`
/// (project.yml) or registration throws; and every scheduler callback must be
/// `@Sendable`, because the scheduler calls them on queues of its own and
/// Swift 6 traps a main-actor closure run anywhere else.
@MainActor
enum GuideRefreshScheduler {
    /// Also in `BGTaskSchedulerPermittedIdentifiers`.
    nonisolated static let identifier = "com.bhavikjain.hearth.guide-refresh"
    /// Guides are refreshed every 6 hours (technical spec, Refresh).
    nonisolated static let interval: TimeInterval = 6 * 60 * 60

    #if os(iOS)
    private static var isRegistered = false
    #endif

    static func register(model: AppModel) {
        #if os(iOS)
        // A second registration of one identifier throws too.
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { @Sendable task in
            // `using: .main` delivers on the main queue; `@Sendable` keeps Swift 6
            // from treating this as a main-actor closure it would check at runtime.
            // BGTask isn't Sendable; it is used only on the main queue it
            // arrived on.
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated { run(task, model: model) }
        }
        #endif
    }

    /// Asks for the next run unless one is already waiting (resubmitting
    /// would push the earliest time back on every foreground).
    static func schedule() {
        #if os(iOS)
        guard isRegistered else { return }
        BGTaskScheduler.shared.getPendingTaskRequests { @Sendable requests in
            guard !requests.contains(where: { $0.identifier == identifier }) else { return }
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
            // Refused on a simulator and with Background App Refresh off;
            // the app then refreshes when opened.
            try? BGTaskScheduler.shared.submit(request)
        }
        #endif
    }

    #if os(iOS)
    private static func run(_ task: BGTask, model: AppModel) {
        nonisolated(unsafe) let task = task
        // The next one first, so a run cut short still leaves one queued.
        schedule()
        let work = Task { @MainActor in
            let finished = await model.backgroundRefresh()
            task.setTaskCompleted(success: finished)
        }
        // iOS ending it early: the refresh is cancellable between sources,
        // and the task is still completed once, above.
        task.expirationHandler = { @Sendable in work.cancel() }
    }
    #endif
}
