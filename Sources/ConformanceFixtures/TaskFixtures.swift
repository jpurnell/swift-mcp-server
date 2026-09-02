import Foundation
import MCP
import SwiftMCPServer
#if canImport(os)
import os
#endif

/// The task-supporting tools the conformance suite names, and the rules that decide whether a
/// call becomes a task at all.
///
/// SEP-2663 makes task creation **server-directed**: the client does not ask for a task, the
/// server decides. What the client does control is whether the extension is negotiated — at
/// session level or for a single call — and a server must not create a task for a client that
/// could not poll for it.
public enum TaskFixtures {

    /// Tools this target runs as tasks when the extension is in play.
    ///
    /// A set rather than a flag on `Tool`: which tools are long-running is a property of this
    /// deployment, not of the wire format, and putting it on the tool would invent a protocol
    /// field the specification does not define.
    public static let taskSupporting: Set<String> = [
        "slow_compute", "failing_job", "protocol_error_job", "confirm_delete", "multi_input",
        "test_tool_with_task",
    ]

    /// Tools that **cannot** run without the extension.
    ///
    /// SEP-2663 §"Required Capabilities": a server that cannot service a request without
    /// returning a `CreateTaskResult` must refuse a client that did not declare the extension,
    /// with `-32021`, rather than quietly doing something else. Falling back to a synchronous
    /// run would answer a different question than the one asked.
    public static let taskRequired: Set<String> = ["failing_job"]

    /// The task-supporting tools, for `tools/list`.
    public static let tools: [Tool] = [
        Tool(
            name: "slow_compute",
            description: "Sleeps for `seconds` and then returns a result",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "seconds": .object(["type": .string("number")]),
                    "label": .object(["type": .string("string")]),
                ]),
            ])),
        Tool(
            name: "failing_job",
            description: "Always reports a tool execution error",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
        Tool(
            name: "protocol_error_job",
            description: "Always ends in a protocol error",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
        Tool(
            name: "confirm_delete",
            description: "Asks the user to confirm, then reports the deletion",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["filename": .object(["type": .string("string")])]),
                "required": .array([.string("filename")]),
            ])),
        Tool(
            name: "multi_input",
            description: "Asks two questions before it can proceed",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
        Tool(
            name: "test_tool_with_task",
            description: "Gathers input synchronously, then escalates to a task",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
    ]

    // MARK: - Negotiation

    /// Whether the tasks extension is in play for this request.
    ///
    /// Two ways in, and both count: a session that declared the extension, and a single call
    /// that opts in through `_meta.io.modelcontextprotocol/clientCapabilities.extensions`
    /// (SEP-2575). The per-request form exists because a stateless client has no session in
    /// which to have negotiated anything.
    ///
    /// - Parameter meta: The request's `_meta`.
    /// - Returns: `true` when the client can poll for a task.
    public static func tasksNegotiated(in meta: Metadata?) -> Bool {
        guard let capabilities = meta?.clientCapabilities else { return false }
        return capabilities.extensions?[TasksExtension.identifier] != nil
    }

    // MARK: - The work

    /// Runs the named fixture's work against `handle`.
    ///
    /// Each of these exists to produce one lifecycle the suite checks: a slow success, a tool
    /// error, a protocol error, and the two input-gathering shapes.
    ///
    /// - Parameters:
    ///   - name: The tool being run.
    ///   - arguments: Its arguments.
    ///   - handle: What the work settles.
    public static func run(
        _ name: String, arguments: [String: Value]?, handle: MCPTaskHandle
    ) async {
        switch name {
        case "slow_compute":
            let seconds = arguments?["seconds"]?.doubleValue ?? 0
            let label = arguments?["label"]?.stringValue ?? "slow_compute"
            if seconds > 0 {
                // A cancelled sleep throws, and by then the store has already recorded
                // `cancelled` — completing here would overwrite the outcome the client asked
                // for. Returning without settling is exactly right, and `isCancellationError`
                // says that this is the only error being treated that way.
                guard await slept(seconds) else { return }
            }
            await handle.complete(toolResult(text: "Computed \(label) in \(seconds)s"))

        case "failing_job":
            guard await slept(1) else { return }
            // A tool that ran and said no: `completed`, with the failure inside the result.
            await handle.complete(toolResult(text: "failing_job always fails", isError: true))

        case "protocol_error_job":
            await handle.fail(.init(
                code: -32603, message: "protocol_error_job raised a protocol error"))

        case "confirm_delete":
            let filename = arguments?["filename"]?.stringValue ?? "unknown"
            await handle.awaitInput([
                "confirm": .elicit(.form(.init(message: "Delete \(filename)?")))
            ])
            guard await waitUntilUnblocked(handle) else { return }
            await handle.complete(toolResult(text: "Deleted \(filename)"))

        case "multi_input":
            await handle.awaitInput([
                "first": .elicit(.form(.init(message: "First value?"))),
                "second": .elicit(.form(.init(message: "Second value?"))),
            ])
            guard await waitUntilUnblocked(handle) else { return }
            await handle.complete(toolResult(text: "Both answers received"))

        case "test_tool_with_task":
            await handle.awaitInput([
                "confirm": .elicit(.form(.init(message: "Proceed?")))
            ])
            guard await waitUntilUnblocked(handle) else { return }
            await handle.complete(toolResult(text: "Escalated to a task and finished"))

        default:
            await handle.fail(.init(code: -32602, message: "Unknown task tool: \(name)"))
        }
    }

    /// Waits for the client to answer, giving up when the task is cancelled or the wait is
    /// abandoned.
    ///
    /// Polled rather than signalled because the store is the only thing that knows an answer
    /// arrived, and a task parked forever would hold its work alive for the process's lifetime.
    ///
    /// - Parameter handle: The parked task.
    /// - Returns: `true` when every question was answered in time.
    private static func waitUntilUnblocked(_ handle: MCPTaskHandle) async -> Bool {
        for _ in 0..<600 {
            if await handle.isUnblocked() { return true }
            guard await slept(0.05) else { return false }
        }
        return false
    }

    /// Sleeps, reporting whether it ran to completion.
    ///
    /// Cancellation is the expected way out of every wait here, and it is not a failure: the
    /// store has already recorded `cancelled`, and settling the task afterwards would overwrite
    /// the outcome the client asked for. Returning `false` rather than rethrowing puts that
    /// decision in one place instead of in three `catch` blocks that each look like a swallowed
    /// error.
    ///
    /// - Parameter seconds: How long to wait.
    /// - Returns: `false` when the wait was cancelled.
    private static func slept(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            // Cancellation is the expected exit and not a failure: the store recorded
            // `cancelled` before it cancelled the work, so there is nothing to report. Anything
            // else means the wait ended for a reason nobody planned for, and the task is about
            // to be abandoned without settling — which silence would make invisible.
            if !(error is CancellationError) {
                logger.error(
                    "A task's wait failed unexpectedly: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    private static let logger = os.Logger(
        subsystem: "com.swiftmcp.conformance", category: "TaskFixtures")

    /// A `CallTool.Result` as a `Value`, which is the shape a task inlines.
    ///
    /// - Parameters:
    ///   - text: The text content.
    ///   - isError: Whether the tool reported a failure.
    /// - Returns: The result, ready to inline on `tasks/get`.
    static func toolResult(text: String, isError: Bool = false) -> Value {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
            "resultType": .string("complete"),
        ])
    }
}
