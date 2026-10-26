import Foundation
import Observation

/// Runs `perform` with `read()`'s value now and again whenever an observable
/// property `read` touches changes to a different value, until the task is
/// cancelled. The app-wide wiring (sources → catalog, profile → filter,
/// refreshes → FAV-2) lives in `AppModel` rather than in a view's
/// `.onChange`, because on iPad and the Mac several windows show the same
/// root and each would run it again.
///
/// `withObservationTracking` reports a change once, from the property's
/// `willSet`; the loop re-reads on its next turn of the main actor, after
/// the write has landed, and tracks again. Bursts of writes collapse into
/// one `perform` with the latest value.
@MainActor
func observeChanges<Value: Equatable>(
    of read: @escaping @MainActor () -> Value,
    perform: @escaping @MainActor (Value) -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        var last = read()
        perform(last)
        while !Task.isCancelled {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = read()
                } onChange: {
                    continuation.resume()
                }
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            let value = read()
            if value != last {
                last = value
                perform(value)
            }
        }
    }
}
