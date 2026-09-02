import Foundation
import Testing

@testable import SwiftMCPServer
import MCP

/// The rules SEP-2663 puts on a task's lifecycle, which are mostly about ordering and about
/// which of two similar-looking outcomes a client is told.
@Suite("Task store")
struct MCPTaskStoreTests {

    /// A store with a pinned clock and predictable identifiers, so a test asserts on the rule
    /// rather than on whatever the wall clock said.
    private func makeStore() -> MCPTaskStore {
        let counter = Counter()
        return MCPTaskStore(
            clock: { Date(timeIntervalSince1970: 1_756_771_200) },
            identifiers: { "task-\(counter.next())" }
        )
    }

    /// A thread-safe counter, so identifiers are stable across the concurrent work the store
    /// starts.
    // Justification: every access takes the lock below, which is the whole implementation
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// Waits for `condition`, so a test observes a settled task rather than racing it.
    private func eventually(
        _ condition: @Sendable () async -> Bool, within seconds: Double = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - Creation

    /// SEP-2663 requires strong consistency: a `tasks/get` issued the instant the client sees
    /// the id must resolve. Recording the task after starting the work would answer `-32602`
    /// for a task the client was just told about.
    @Test("A task is readable the moment its identifier exists")
    func testTaskIsReadableImmediately() async throws {
        let store = makeStore()
        let task = await store.create { handle in
            // Deliberately slow: if creation returned before recording, this is the window in
            // which the read below would fail.
            try? await Task.sleep(for: .seconds(5))
            await handle.complete(.object([:]))
        }

        let detailed = try #require(await store.detailedTask(task.taskId))
        #expect(detailed.taskId == task.taskId)
        #expect(detailed.status == .working)
        await store.cancel(task.taskId)
    }

    @Test("A task starts working, with timestamps and a polling hint")
    func testNewTaskShape() async throws {
        let store = makeStore()
        let task = await store.create(ttlMs: 30_000, pollIntervalMs: 250) { _ in }

        #expect(task.status == .working)
        #expect(task.ttlMs == 30_000)
        #expect(task.pollIntervalMs == 250)
        #expect(task.createdAt == task.lastUpdatedAt, "nothing has happened to it yet")
        #expect(!task.createdAt.isEmpty)
    }

    // MARK: - Settling

    @Test("Completed work is inlined on the task")
    func testCompletionInlinesResult() async throws {
        let store = makeStore()
        let task = await store.create { handle in
            await handle.complete(.object(["content": .array([.string("done")])]))
        }

        #expect(await eventually { await store.detailedTask(task.taskId)?.status == .completed })
        let detailed = try #require(await store.detailedTask(task.taskId))
        #expect(detailed.result?.objectValue?["content"]?.arrayValue?.count == 1)
        #expect(detailed.error == nil)
    }

    /// The distinction the specification is most insistent about: a tool that ran and reported
    /// failure is `completed` with `isError`, and `failed` means the call never produced a
    /// result at all. A client that cannot tell them apart cannot know whether to retry.
    @Test("A tool error completes; only a protocol error fails")
    func testToolErrorCompletesAndProtocolErrorFails() async throws {
        let store = makeStore()

        let toolError = await store.create { handle in
            await handle.complete(.object([
                "content": .array([.object(["type": .string("text")])]),
                "isError": .bool(true),
            ]))
        }
        let protocolError = await store.create { handle in
            await handle.fail(.init(code: -32603, message: "Internal error"))
        }

        #expect(await eventually {
            await store.detailedTask(toolError.taskId)?.status == .completed
        })
        let ranAndSaidNo = try #require(await store.detailedTask(toolError.taskId))
        #expect(ranAndSaidNo.status == .completed)
        #expect(ranAndSaidNo.result?.objectValue?["isError"]?.boolValue == true)
        #expect(ranAndSaidNo.error == nil)

        #expect(await eventually {
            await store.detailedTask(protocolError.taskId)?.status == .failed
        })
        let neverRan = try #require(await store.detailedTask(protocolError.taskId))
        #expect(neverRan.status == .failed)
        #expect(neverRan.result == nil, "a protocol failure produced no result")
        #expect(neverRan.error?.code == -32603)
    }

    // MARK: - Cancellation

    /// The whole point of cancelling: the terminal status must be `cancelled`, not whatever the
    /// work would have produced had it been left alone.
    @Test("A cancelled task settles cancelled, even if its work finishes anyway")
    func testCancellationWins() async throws {
        let store = makeStore()
        let task = await store.create { handle in
            // Ignores cancellation deliberately — a real tool may be mid-syscall and finish
            // regardless, and the store must not let that overwrite the recorded outcome.
            try? await Task.sleep(for: .milliseconds(50))
            await handle.complete(.object(["content": .array([])]))
        }

        #expect(await store.cancel(task.taskId))
        #expect(await store.detailedTask(task.taskId)?.status == .cancelled)

        // Give the work time to try to complete on top of the cancellation.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await store.detailedTask(task.taskId)?.status == .cancelled)
        #expect(await store.detailedTask(task.taskId)?.result == nil)
    }

    /// `-32602` is reserved for identifiers the server does not recognise; a client retrying a
    /// cancel has done nothing wrong.
    @Test("Cancelling twice is acknowledged twice")
    func testCancellationIsIdempotent() async throws {
        let store = makeStore()
        let task = await store.create { handle in
            try? await Task.sleep(for: .seconds(5))
            await handle.complete(.object([:]))
        }

        #expect(await store.cancel(task.taskId))
        #expect(await store.cancel(task.taskId), "a terminal task still acknowledges")
        #expect(await store.detailedTask(task.taskId)?.status == .cancelled)
    }

    @Test("Cancelling something that does not exist is not acknowledged")
    func testCancellingUnknownTask() async {
        let store = makeStore()
        #expect(await store.cancel("no-such-task") == false)
        #expect(await store.detailedTask("no-such-task") == nil)
    }

    // MARK: - Input

    @Test("A parked task surfaces what it is waiting for")
    func testAwaitingInput() async throws {
        let store = makeStore()
        let task = await store.create { handle in
            await handle.awaitInput(["confirm": .elicit(.form(.init(message: "Delete it?")))])
            while await !handle.isUnblocked() {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await handle.complete(.object(["content": .array([])]))
        }

        #expect(await eventually {
            await store.detailedTask(task.taskId)?.status == .inputRequired
        })
        let parked = try #require(await store.detailedTask(task.taskId))
        #expect(Array(parked.inputRequests?.keys ?? [:].keys) == ["confirm"])
    }

    /// A task asking three questions and given one has not been unblocked, and resuming it
    /// would run work that still cannot proceed.
    @Test("A partial answer leaves only the unanswered questions outstanding")
    func testPartialFulfilment() async throws {
        let store = makeStore()
        let task = await store.create { handle in
            await handle.awaitInput([
                "first": .elicit(.form(.init(message: "First?"))),
                "second": .elicit(.form(.init(message: "Second?"))),
            ])
            try? await Task.sleep(for: .seconds(5))
        }

        #expect(await eventually {
            await store.detailedTask(task.taskId)?.status == .inputRequired
        })

        #expect(await store.supply(task.taskId, responses: ["first": .elicit(.init(action: .decline))]))
        let stillParked = try #require(await store.detailedTask(task.taskId))
        #expect(stillParked.status == .inputRequired)
        #expect(
            Array(stillParked.inputRequests?.keys ?? [:].keys) == ["second"],
            "only the unanswered question stays outstanding")

        await store.cancel(task.taskId)
    }

    /// A client that retries with a superset of what it already sent has done nothing wrong.
    @Test("Answers to questions that were not asked are ignored, not refused")
    func testUnaskedAnswersIgnored() async throws {
        let store = makeStore()
        let task = await store.create { handle in
            await handle.awaitInput(["confirm": .elicit(.form(.init(message: "Delete it?")))])
            try? await Task.sleep(for: .seconds(5))
        }

        #expect(await eventually {
            await store.detailedTask(task.taskId)?.status == .inputRequired
        })
        #expect(await store.supply(task.taskId, responses: [
            "confirm": .elicit(.init(action: .decline)),
            "unasked": .elicit(.init(action: .decline)),
        ]))

        #expect(await store.isUnblocked(task.taskId))
        #expect(await store.responses(for: task.taskId).keys.sorted() == ["confirm"])
    }

    @Test("Supplying input to something that does not exist is refused")
    func testSupplyingUnknownTask() async {
        let store = makeStore()
        #expect(await store.supply("no-such-task", responses: [:]) == false)
    }
}
