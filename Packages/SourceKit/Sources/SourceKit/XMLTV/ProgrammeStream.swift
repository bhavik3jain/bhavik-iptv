import Foundation

/// A bounded hand-off from a producer thread (the XML parser) to an async
/// consumer (CatalogKit's import). `AsyncThrowingStream`'s own buffer is
/// unbounded, and a guide can hold a million programmes; a parser that runs
/// ahead of a slow store write would hold them all in memory. Here the parser
/// thread blocks once `capacity` programmes are waiting.
///
/// `@unchecked Sendable`: every mutable property is read and written only
/// while `condition` is locked, and the producer side runs on its own thread
/// (never the cooperative pool), so blocking it is fine.
final class ProgrammeChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var buffer: [RemoteProgramme] = []
    private var head = 0
    private var waiter: CheckedContinuation<RemoteProgramme?, Error>?
    private var finished = false
    private var failure: Error?
    private var cancelled = false
    private var starter: (@Sendable () -> Void)?

    init(capacity: Int = 2_000) {
        self.capacity = capacity
    }

    /// The work that fills the channel, run on the first `next()` so a guide
    /// nobody reads is never downloaded.
    func setStarter(_ starter: @escaping @Sendable () -> Void) {
        condition.lock()
        self.starter = starter
        condition.unlock()
    }

    var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    // MARK: Producer

    /// Hands one programme over, blocking while the consumer is behind.
    /// Returns false once the consumer has gone, so the producer can stop.
    @discardableResult
    func send(_ programme: RemoteProgramme) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if cancelled { return false }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: programme)
            return true
        }
        buffer.append(programme)
        while buffer.count - head >= capacity, !cancelled {
            condition.wait()
        }
        return !cancelled
    }

    func finish(throwing error: Error? = nil) {
        condition.lock()
        defer { condition.unlock() }
        guard !finished else { return }
        finished = true
        failure = error
        if let waiter, head >= buffer.count {
            self.waiter = nil
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
    }

    // MARK: Consumer

    func next() async throws -> RemoteProgramme? {
        if let starter = takeStarter() { starter() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteProgramme?, Error>) in
                condition.lock()
                defer { condition.unlock() }
                if head < buffer.count {
                    let programme = buffer[head]
                    head += 1
                    if head >= 4_096, head * 2 >= buffer.count {
                        buffer.removeFirst(head)
                        head = 0
                    }
                    if buffer.count - head <= capacity / 2 { condition.broadcast() }
                    continuation.resume(returning: programme)
                } else if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if finished {
                    if let failure {
                        self.failure = nil
                        continuation.resume(throwing: failure)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Stops the producer: the consumer was cancelled or let go of the stream.
    func cancel() {
        condition.lock()
        defer { condition.unlock() }
        cancelled = true
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: CancellationError())
        }
        condition.broadcast()
    }

    private func takeStarter() -> (@Sendable () -> Void)? {
        condition.lock()
        defer { condition.unlock() }
        let starter = self.starter
        self.starter = nil
        return starter
    }
}

/// Held by the stream's unfolding closure: when the consumer drops the stream
/// (breaks out of its loop, or its task ends) this goes away and the producer
/// is told to stop instead of blocking forever on a full buffer.
private final class ConsumerToken: Sendable {
    let channel: ProgrammeChannel
    init(_ channel: ProgrammeChannel) { self.channel = channel }
    deinit { channel.cancel() }
}

enum ProgrammeStream {
    /// A stream whose programmes come from `work`, started lazily and stopped
    /// when the consumer goes away.
    static func make(
        capacity: Int = 2_000,
        _ work: @escaping @Sendable (ProgrammeChannel) async throws -> Void
    ) -> AsyncThrowingStream<RemoteProgramme, Error> {
        let channel = ProgrammeChannel(capacity: capacity)
        channel.setStarter {
            Task.detached(priority: .utility) {
                do {
                    try await work(channel)
                    channel.finish()
                } catch {
                    channel.finish(throwing: error)
                }
            }
        }
        let token = ConsumerToken(channel)
        return AsyncThrowingStream(unfolding: { try await token.channel.next() })
    }
}
