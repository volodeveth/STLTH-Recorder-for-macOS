import Foundation
import Testing
@testable import RecorderCore

@Suite("SerialTaskQueue")
struct SerialTaskQueueTests {

    /// Records what happened, in order, from any task.
    private actor Log {
        private(set) var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    /// Holds a job until the test lets it go.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private struct Failure: Error {}

    @Test("The second job does not start until the first has finished")
    func jobsNeverOverlap() async throws {
        let queue = SerialTaskQueue()
        let log = Log()
        let gate = Gate()

        let first = await queue.enqueue {
            await log.add("A start")
            await gate.wait()
            await log.add("A end")
        }
        let second = await queue.enqueue {
            await log.add("B start")
            await log.add("B end")
        }

        // Give B every chance to start early. It must not.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await log.events == ["A start"])

        await gate.open()
        try await first.value
        try await second.value
        #expect(await log.events == ["A start", "A end", "B start", "B end"])
    }

    @Test("A failing job does not block the ones behind it")
    func failureReleasesQueue() async throws {
        let queue = SerialTaskQueue()
        let failing = await queue.enqueue { throw Failure() }
        let next = await queue.enqueue { 42 }

        await #expect(throws: Failure.self) { try await failing.value }
        #expect(try await next.value == 42)
    }

    @Test("Jobs run in the order they were enqueued")
    func preservesOrder() async throws {
        let queue = SerialTaskQueue()
        let log = Log()
        var tasks: [Task<Void, Error>] = []
        for index in 0..<20 {
            tasks.append(await queue.enqueue { await log.add("\(index)") })
        }
        for task in tasks { try await task.value }
        #expect(await log.events == (0..<20).map(String.init))
    }

    @Test("A job's value reaches its caller")
    func returnsValue() async throws {
        let queue = SerialTaskQueue()
        let answer = await queue.enqueue { "готово" }
        #expect(try await answer.value == "готово")
    }
}
