import Foundation
import MCP
import SwiftMCPServer

/// `tools/call` with the tasks extension in play, and the `tasks/*` methods that follow from it.
///
/// Registered as a separate surface because the *response shape* differs: a task-supporting call
/// answers with a flat `CreateTaskResult` rather than a `CallTool.Result`, and a typed handler
/// can only return one of those. The method name is the same one `registerTools` uses, and the
/// later registration wins — which is why this is applied after it and says so here rather than
/// leaving the ordering to be discovered.
enum TasksSurface {

    /// `tools/call`, seen as a method that may answer with either shape.
    ///
    /// `Value` rather than a union type: the two results have no fields in common beyond
    /// `resultType`, and a union would exist only to be immediately flattened onto the wire.
    // `MCP.Method` qualified: SwiftMCPServer also vends a `Method`, and an unqualified
    // reference here resolves to neither.
    private enum TaskAwareCallTool: MCP.Method {
        static let name = CallTool.name
        typealias Parameters = CallTool.Parameters
        typealias Result = Value
    }

    /// Registers task dispatch and the `tasks/*` methods.
    ///
    /// - Parameters:
    ///   - server: The server to register on.
    ///   - store: Where tasks live.
    ///   - synchronousCall: How to run a tool when no task is created — the same handler
    ///     `registerTools` installed, reached through here so the two cannot answer differently.
    static func register(
        on server: Server,
        store: MCPTaskStore,
        synchronousCall: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result
    ) async {
        await server.withMethodHandler(TaskAwareCallTool.self) { parameters in
            // SEP-2322 first: a tool that needs input answers with the questions, whatever the
            // tasks extension is doing. The two compose — `test_tool_with_task` gathers input
            // synchronously and only then escalates — so the input round has to come first or
            // the escalation happens before anything has been asked.
            if InputRequiredFixtures.handles(parameters.name) {
                let answer = try InputRequiredFixtures.respond(
                    to: parameters.name,
                    responses: parameters.inputResponses,
                    requestState: parameters.requestState,
                    capabilities: parameters._meta?.clientCapabilities)
                switch answer {
                case .needsInput(let interim):
                    return try encode(interim)
                case .complete(let text):
                    return try encode(CallTool.Result(
                        content: [.text(text: text, annotations: nil, _meta: nil)],
                        isError: false, resultType: .complete))
                }
            }

            // Server-directed, but not unilateral: a client that did not negotiate the extension
            // has no way to poll, so the same tool runs synchronously for it. SEP-2663 requires
            // exactly this fallback rather than an error.
            let negotiated = TaskFixtures.tasksNegotiated(in: parameters._meta)

            // A tool that can only run as a task is refused rather than run some other way: the
            // client would otherwise get an answer to a question it did not ask.
            if TaskFixtures.taskRequired.contains(parameters.name), !negotiated {
                throw MCPError.missingRequiredClientCapability(
                    requiringExtensions: [TasksExtension.identifier])
            }

            guard TaskFixtures.taskSupporting.contains(parameters.name), negotiated else {
                return try encode(try await synchronousCall(parameters))
            }

            // SEP-2663 composed with SEP-2322: gather what is needed *synchronously* first,
            // and only escalate once there is nothing left to ask. Creating the task first
            // would hand the client a task id for work that cannot start, and the answers
            // would then have to arrive through `tasks/update` — a different mechanism for the
            // same question, chosen by an accident of ordering.
            if parameters.name == "test_tool_with_task" {
                guard let supplied = parameters.inputResponses?["user_name"],
                    let who = InputRequiredFixtures.elicitedName(from: supplied)
                else {
                    return try encode(InputRequiredResult(inputRequests: [
                        "user_name": InputRequiredFixtures.nameQuestion
                    ]))
                }
                let task = await store.create { handle in
                    await handle.complete(TaskFixtures.toolResult(
                        text: "Completed the task for \(who)"))
                }
                return try encode(CreateTaskResult(task: task))
            }

            let name = parameters.name
            let arguments = parameters.arguments
            let task = await store.create { handle in
                await TaskFixtures.run(name, arguments: arguments, handle: handle)
            }
            return try encode(CreateTaskResult(task: task))
        }

        await server.withMethodHandler(GetTask.self) { parameters in
            try requireTasksNegotiated(parameters._meta)
            guard let detailed = await store.detailedTask(parameters.taskId) else {
                throw MCPError.invalidParams("Unknown taskId: \(parameters.taskId)")
            }
            return detailed
        }

        await server.withMethodHandler(UpdateTask.self) { parameters in
            try requireTasksNegotiated(parameters._meta)
            guard await store.supply(
                parameters.taskId, responses: parameters.inputResponses ?? [:])
            else {
                throw MCPError.invalidParams("Unknown taskId: \(parameters.taskId)")
            }
            return UpdateTask.Result()
        }

        await server.withMethodHandler(CancelTask.self) { parameters in
            try requireTasksNegotiated(parameters._meta)
            guard await store.cancel(parameters.taskId) else {
                throw MCPError.invalidParams("Unknown taskId: \(parameters.taskId)")
            }
            return CancelTask.Result()
        }
    }

    /// Refuses a `tasks/*` request from a client that never negotiated the extension.
    ///
    /// `-32021` and not `-32601`: the method exists, and saying "no such method" would tell the
    /// client to stop asking rather than to declare the capability and retry.
    ///
    /// - Parameter meta: The request's `_meta`.
    private static func requireTasksNegotiated(_ meta: Metadata?) throws {
        guard TaskFixtures.tasksNegotiated(in: meta) else {
            throw MCPError.missingRequiredClientCapability(
                requiringExtensions: [TasksExtension.identifier])
        }
    }

    /// Renders a typed result as the `Value` the shared handler returns.
    ///
    /// - Parameter result: The result to render.
    /// - Returns: The same result, as a JSON value.
    private static func encode(_ result: some Encodable) throws -> Value {
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
