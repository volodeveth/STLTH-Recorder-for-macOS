import Foundation

/// Runs jobs one after another, never two at once.
///
/// Transcription loads the CPU for roughly as long as the conversation lasted, per
/// track. Two sessions stopped in a row would start two whisper processes side by
/// side, each at half speed, on the machine of someone who has just hung up. So: a
/// queue. Not a semaphore — Swift concurrency has no blocking primitive that is safe
/// to hold across an `await` — but a chain of tasks, each waiting for the previous
/// one to finish before it starts. A job that throws releases the chain like any
/// other; only its own caller sees the error.
public actor SerialTaskQueue {

    private var tail: Task<Void, Never>?

    public init() {}

    /// Enqueue `work`. It starts after everything enqueued before it has finished —
    /// whether that finished by returning or by throwing.
    @discardableResult
    public func enqueue<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) -> Task<T, Error> {
        let previous = tail
        // Detached, so a job that blocks a thread (whisper does, for minutes) never
        // holds this actor and never lands on the caller's executor.
        let task = Task.detached(priority: .utility) {
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return task
    }
}
