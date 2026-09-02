import Foundation
import MCP

/// Runs work that outlives the request that asked for it, and remembers what it produced.
///
/// The `io.modelcontextprotocol/tasks` extension (SEP-2663) exists because a stateless protocol
/// has no channel for a server to call back on: a client sends a request, gets a `taskId`, and
/// polls. Everything hard about that is here — a task must be readable the instant its id is
/// returned, cancellation must settle to `cancelled` rather than to whatever the work would
/// have produced, and a tool that ran and said no must stay distinguishable from a tool that
/// could not run at all.
///
/// ## Durability
///
/// This store is in-memory and lives as long as the process. That is the right scope for a
/// single-instance server and the wrong one for a fleet: a task created on one instance is
/// invisible to another, so a load-balanced deployment needs a shared store rather than this.
/// The type is an actor and its surface is small enough to reimplement against a database.
public actor MCPTaskStore {

    /// A task and everything known about it.
    private struct Entry {
        var task: MCPTask
        var result: Value?
        var error: TaskError?
        var inputRequests: [String: InputRequest]?
        /// The work in flight, so cancellation can stop it.
        var work: Task<Void, Never>?
        /// Answers supplied through `tasks/update`, awaiting the work that asked for them.
        var inputResponses: [String: InputResponse] = [:]
    }

    private var entries: [String: Entry] = [:]
    private let clock: @Sendable () -> Date
    private let identifiers: @Sendable () -> String

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - clock: Supplies timestamps. Injected so a test can pin them rather than assert on
    ///     whatever the wall clock happened to say.
    ///   - identifiers: Supplies task identifiers, for the same reason.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        identifiers: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.clock = clock
        self.identifiers = identifiers
    }

    /// An ISO-8601 timestamp, which is the format the specification requires.
    private var now: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: clock())
    }

    // MARK: - Creating

    /// Creates a task and starts its work.
    ///
    /// The task is recorded **before** `work` begins, so a `tasks/get` issued the moment the
    /// caller sees the id resolves. SEP-2663 requires that ordering explicitly, and getting it
    /// backwards produces a `-32602` for a task the client was just told about.
    ///
    /// - Parameters:
    ///   - ttlMs: How long the task stays readable, or `nil` for unlimited.
    ///   - pollIntervalMs: How often the client should poll.
    ///   - work: The work to run. Its outcome settles the task.
    /// - Returns: The created task, ready to be returned as a `CreateTaskResult`.
    @discardableResult
    public func create(
        ttlMs: Int? = 60_000,
        pollIntervalMs: Int? = 500,
        work: @escaping @Sendable (MCPTaskHandle) async -> Void
    ) -> MCPTask {
        let timestamp = now
        let task = MCPTask(
            taskId: identifiers(),
            status: .working,
            createdAt: timestamp,
            lastUpdatedAt: timestamp,
            ttlMs: ttlMs,
            pollIntervalMs: pollIntervalMs
        )
        entries[task.taskId] = Entry(task: task)

        let handle = MCPTaskHandle(taskId: task.taskId, store: self)
        entries[task.taskId]?.work = Task { await work(handle) }
        return task
    }

    // MARK: - Reading

    /// A task's full state, or `nil` if this store has never heard of it.
    ///
    /// `nil` rather than a placeholder: an unknown `taskId` is `-32602`, and a placeholder would
    /// have the server answering for work it never started.
    ///
    /// - Parameter taskId: The task to read.
    /// - Returns: The task's state, inlining its result, error or outstanding input requests.
    public func detailedTask(_ taskId: String) -> DetailedTask? {
        guard let entry = entries[taskId] else { return nil }
        return DetailedTask(
            task: entry.task,
            result: entry.result,
            error: entry.error,
            inputRequests: entry.inputRequests,
            resultType: .complete
        )
    }

    /// Whether this store knows the task.
    ///
    /// - Parameter taskId: The task to look for.
    /// - Returns: `true` when it exists.
    public func contains(_ taskId: String) -> Bool { entries[taskId] != nil }

    // MARK: - Settling

    /// Records that a task finished with a result.
    ///
    /// A tool that ran and reported failure lands here too, as `completed` with `isError` inside
    /// its result. `failed` is reserved for a protocol error, which is what ``fail(_:with:)``
    /// records — conflating them tells a client the call never happened when in fact it ran and
    /// said no.
    ///
    /// A cancelled task is left cancelled: the work may finish after the cancellation is
    /// recorded, and overwriting the status then would make cancellation unobservable.
    ///
    /// - Parameters:
    ///   - taskId: The task that finished.
    ///   - result: What it produced.
    public func complete(_ taskId: String, with result: Value) {
        guard var entry = entries[taskId], !entry.task.status.isTerminal else { return }
        entry.result = result
        entry.inputRequests = nil
        entry.task.status = .completed
        entry.task.lastUpdatedAt = now
        entries[taskId] = entry
    }

    /// Records that a task ended in a protocol error.
    ///
    /// - Parameters:
    ///   - taskId: The task that failed.
    ///   - error: The JSON-RPC error that ended it.
    public func fail(_ taskId: String, with error: TaskError) {
        guard var entry = entries[taskId], !entry.task.status.isTerminal else { return }
        entry.error = error
        entry.result = nil
        entry.inputRequests = nil
        entry.task.status = .failed
        entry.task.lastUpdatedAt = now
        entries[taskId] = entry
    }

    /// Parks a task until the client supplies what it asked for.
    ///
    /// - Parameters:
    ///   - taskId: The task that needs input.
    ///   - inputRequests: What it is waiting for, keyed so answers can be matched to questions.
    public func awaitInput(_ taskId: String, inputRequests: [String: InputRequest]) {
        guard var entry = entries[taskId], !entry.task.status.isTerminal else { return }
        entry.inputRequests = inputRequests
        entry.task.status = .inputRequired
        entry.task.lastUpdatedAt = now
        entries[taskId] = entry
    }

    // MARK: - Cancelling

    /// Cancels a task, if it is still running.
    ///
    /// Idempotent: cancelling a task that has already settled is acknowledged and changes
    /// nothing, because the specification reserves `-32602` for identifiers the server does not
    /// recognise and a client retrying a cancel has done nothing wrong.
    ///
    /// - Parameter taskId: The task to cancel.
    /// - Returns: `false` only when no such task exists.
    @discardableResult
    public func cancel(_ taskId: String) -> Bool {
        guard var entry = entries[taskId] else { return false }
        guard !entry.task.status.isTerminal else { return true }

        entry.work?.cancel()
        entry.work = nil
        entry.inputRequests = nil
        entry.task.status = .cancelled
        entry.task.lastUpdatedAt = now
        entries[taskId] = entry
        return true
    }

    // MARK: - Supplying input

    /// Hands answers to a task that is waiting for them.
    ///
    /// Answers for questions the task did not ask are ignored rather than rejected: the request
    /// is not malformed, and refusing it would make a client that retries with a superset of
    /// what it already sent fail on the retry.
    ///
    /// - Parameters:
    ///   - taskId: The task being answered.
    ///   - responses: The answers, keyed to the outstanding requests.
    /// - Returns: `false` only when no such task exists.
    @discardableResult
    public func supply(_ taskId: String, responses: [String: InputResponse]) -> Bool {
        guard var entry = entries[taskId] else { return false }
        for (key, response) in responses where entry.inputRequests?[key] != nil {
            entry.inputResponses[key] = response
        }

        // Whatever is still unanswered keeps the task parked. A task asking three questions and
        // given one has not been unblocked, and reporting otherwise would resume work that
        // still cannot proceed.
        let outstanding = (entry.inputRequests ?? [:]).filter { entry.inputResponses[$0.key] == nil }
        entry.inputRequests = outstanding.isEmpty ? nil : outstanding
        entry.task.status = outstanding.isEmpty ? .working : .inputRequired
        entry.task.lastUpdatedAt = now
        entries[taskId] = entry
        return true
    }

    /// The answers supplied for a task so far.
    ///
    /// - Parameter taskId: The task to read.
    /// - Returns: Answers keyed as they were requested.
    public func responses(for taskId: String) -> [String: InputResponse] {
        entries[taskId]?.inputResponses ?? [:]
    }

    /// Whether every question a task asked has been answered.
    ///
    /// - Parameter taskId: The task to check.
    /// - Returns: `true` when nothing is outstanding.
    public func isUnblocked(_ taskId: String) -> Bool {
        entries[taskId]?.inputRequests == nil
    }
}

/// What a task's own work uses to report back.
///
/// Handed to the closure ``MCPTaskStore/create(ttlMs:pollIntervalMs:work:)`` runs, so the work
/// settles its own task without holding a reference to the store's internals or knowing its own
/// identifier twice.
public struct MCPTaskHandle: Sendable {
    /// The task this handle settles.
    public let taskId: String
    private let store: MCPTaskStore

    init(taskId: String, store: MCPTaskStore) {
        self.taskId = taskId
        self.store = store
    }

    /// Records a result and marks the task completed.
    ///
    /// - Parameter result: What the work produced.
    public func complete(_ result: Value) async {
        await store.complete(taskId, with: result)
    }

    /// Records a protocol error and marks the task failed.
    ///
    /// - Parameter error: The error that ended the work.
    public func fail(_ error: TaskError) async {
        await store.fail(taskId, with: error)
    }

    /// Parks the task until the client answers.
    ///
    /// - Parameter requests: What the work needs, keyed so answers can be matched to questions.
    public func awaitInput(_ requests: [String: InputRequest]) async {
        await store.awaitInput(taskId, inputRequests: requests)
    }

    /// The answers supplied so far.
    ///
    /// - Returns: Answers keyed as they were requested.
    public func responses() async -> [String: InputResponse] {
        await store.responses(for: taskId)
    }

    /// Whether every question has been answered.
    ///
    /// - Returns: `true` when nothing is outstanding.
    public func isUnblocked() async -> Bool {
        await store.isUnblocked(taskId)
    }
}
