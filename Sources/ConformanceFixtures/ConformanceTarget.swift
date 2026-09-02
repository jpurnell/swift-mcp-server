import Foundation
import MCP
import SwiftMCPServer

/// Tracks what a conformance target has been asked to watch.
///
/// `resources/subscribe` is only observable through what the server does afterwards, so the set
/// has to be kept even though this target never changes a resource on its own.
public actor SubscriptionState {
    private var subscribed: Set<String> = []

    /// Creates an empty subscription set.
    public init() {}

    /// Records that `uri` is being watched.
    /// - Parameter uri: The resource the client subscribed to.
    public func subscribe(to uri: String) { subscribed.insert(uri) }
    /// Forgets a subscription.
    /// - Parameter uri: The resource the client unsubscribed from.
    public func unsubscribe(from uri: String) { subscribed.remove(uri) }
    /// Whether `uri` is being watched.
    /// - Parameter uri: The resource to check.
    /// - Returns: `true` when a subscription is open for it.
    public func isSubscribed(to uri: String) -> Bool { subscribed.contains(uri) }
}

/// Builds the server the official MCP conformance suite drives.
///
/// It registers the fixtures the suite names — see ``Fixtures`` — because most scenarios call a
/// specific tool, prompt or resource and assert on what comes back. Everything protocol-shaped
/// comes from `SwiftMCPServer` and the SDK; this decides only *what* to expose, never how the
/// wire behaves, so a passing run measures the package rather than this harness.
///
/// Lives in a library rather than the executable so the package's own tests can stand up the
/// identical server. Two definitions of "the conformance target" would drift, and then a green
/// `swift test` and a green harness run would be answering different questions.
public enum ConformanceTarget {

    /// The capabilities this target declares, in discovery and at construction alike.
    ///
    /// Stated once: discovery that disagrees with what is actually registered is the one thing a
    /// stateless client cannot detect, because discovery is all it gets to ask.
    public static var capabilities: Server.Capabilities {
        .init(
            completions: .init(),
            extensions: [TasksExtension.identifier: .object([:])],
            logging: .init(),
            prompts: .init(listChanged: true),
            resources: .init(subscribe: true, listChanged: true),
            tools: .init(listChanged: true)
        )
    }

    /// Every tool this target serves.
    ///
    /// Stated once and handed to both the server and the transport: the transport reads the
    /// `x-mcp-header` annotations out of these, so a tool the two disagree about is a tool whose
    /// header rules go unenforced.
    public static var tools: [Tool] {
        Fixtures.tools + TaskFixtures.tools + InputRequiredFixtures.tools
    }

    /// The change notifications this target can produce.
    ///
    /// Matches what ``capabilities`` declares: a server that acknowledges a subscription it
    /// cannot serve leaves the client waiting for notifications that will never come, and
    /// declaring one capability while honouring another is the same failure in two places.
    public static let subscribableNotifications: Set<String> = [
        "toolsListChanged", "promptsListChanged", "resourcesListChanged",
    ]

    /// Assembles the conformance target and registers every fixture handler on it.
    ///
    /// - Parameter subscriptions: Where `resources/subscribe` records what it was asked to watch.
    /// - Returns: The server, not yet started.
    public static func makeServer(
        subscriptions: SubscriptionState,
        tasks: MCPTaskStore = MCPTaskStore(),
        streams: SubscriptionStreamRegistry? = nil
    ) async -> Server {
        let server = Server(
            name: "swiftmcpserver-conformance",
            version: "1.0.0",
            capabilities: capabilities
        )

        await registerDiscovery(on: server)
        await registerTools(on: server, streams: streams)
        await registerPrompts(on: server)
        await registerResources(on: server, subscriptions: subscriptions)
        await registerUtilities(on: server)

        // Last, and deliberately: it re-registers `tools/call` to answer with either a tool
        // result or a task envelope, and hands the synchronous path back to the handler
        // installed above so the two cannot answer differently.
        await TasksSurface.register(on: server, store: tasks) { parameters in
            try await callTool(parameters, server: server, streams: streams)
        }
        return server
    }

    // MARK: - Discovery

    private static func registerDiscovery(on server: Server) async {
        await server.withMethodHandler(Discover.self) { _ in
            Discover.Result(
                supportedVersions: Version.supported.sorted(by: >),
                capabilities: .init(
                    completions: .init(),
                    extensions: [TasksExtension.identifier: .object([:])],
                    logging: .init(),
                    prompts: .init(listChanged: true),
                    resources: .init(subscribe: true, listChanged: true),
                    tools: .init(listChanged: true)
                ),
                instructions: "Conformance target for SwiftMCPServer.",
                resultType: .complete,
                ttlMs: 3_600_000,
                cacheScope: .public
            )
        }
    }

    // MARK: - Tools

    private static func registerTools(on server: Server, streams: SubscriptionStreamRegistry?) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(
tools: tools, resultType: .complete, ttlMs: 60_000, cacheScope: .public)
        }

        await server.withMethodHandler(CallTool.self) { [weak server] parameters in
            try await callTool(parameters, server: server, streams: streams)
        }
    }

    /// Runs a tool synchronously.
    ///
    /// Named rather than inlined into the handler because the tasks surface needs the same
    /// answer for a client that did not negotiate the extension, and two copies would drift.
    ///
    /// - Parameters:
    ///   - parameters: The call.
    ///   - server: The server, for the notifications some fixtures send while running.
    /// - Returns: The tool's result.
    static func callTool(
        _ parameters: CallTool.Parameters, server: Server?,
        streams: SubscriptionStreamRegistry? = nil
    ) async throws -> CallTool.Result {
        if TaskFixtures.taskSupporting.contains(parameters.name) {
            // Reached when the extension was not negotiated: the same tool, run to completion
            // rather than parked. The input-gathering fixtures have nothing to gather from a
            // client that cannot be asked, so they answer directly.
            return .init(
                content: [.text(
                    text: "\(parameters.name) ran synchronously", annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)
        }

        switch parameters.name {
            case "test_simple_text":
                return .init(
                    content: [.text(
                        text: "This is a simple text response for testing.", annotations: nil,
                        _meta: nil)],
                    isError: false, resultType: .complete)

            case "test_image_content":
                return .init(
                    content: [.image(
                        data: Fixtures.imageBase64, mimeType: "image/png", annotations: nil,
                        _meta: nil)],
                    isError: false, resultType: .complete)

            case "test_audio_content":
                return .init(
                    content: [.audio(
                        data: Fixtures.audioBase64, mimeType: "audio/wav", annotations: nil,
                        _meta: nil)],
                    isError: false, resultType: .complete)

            case "test_embedded_resource":
                return .init(
                    content: [.resource(resource: .text(
                        "This is an embedded resource content.", uri: "test://embedded-resource",
                        mimeType: "text/plain"))],
                    isError: false, resultType: .complete)

            case "test_multiple_content_types":
                return .init(
                    content: [
                        .text(
                            text: "Multiple content types test:", annotations: nil, _meta: nil),
                        .image(
                            data: Fixtures.imageBase64, mimeType: "image/png", annotations: nil,
                            _meta: nil),
                        .resource(resource: .text(
                            #"{"test":"data","value":123}"#, uri: "test://mixed-content-resource",
                            mimeType: "application/json")),
                    ],
                    isError: false, resultType: .complete)

            case "test_error_handling":
                // `isError: true` on a successful JSON-RPC response, not a JSON-RPC error: the
                // tool ran and reported a failure, which is a result rather than a protocol
                // fault. The distinction is the whole subject of this scenario.
                return .init(
                    content: [.text(
                        text: "This tool intentionally returns an error for testing",
                        annotations: nil, _meta: nil)],
                    isError: true, resultType: .complete)

            case "test_tool_with_logging":
                for message in [
                    "Tool execution started", "Tool processing data", "Tool execution completed",
                ] {
                    try await server?.notify(
                        LogMessageNotification.message(
                            .init(level: .info, data: .string(message))))
                    // The delay is the point: a client that batches or drops notifications while
                    // a call is in flight passes without it.
                    try await Task.sleep(for: .milliseconds(50))
                }
                return .init(
                    content: [.text(
                        text: "Logging test completed", annotations: nil, _meta: nil)],
                    isError: false, resultType: .complete)

            case "test_tool_with_progress":
                if let token = parameters._meta?.progressToken {
                    for progress in [0.0, 50.0, 100.0] {
                        try await server?.notify(
                            ProgressNotification.message(
                                .init(progressToken: token, progress: progress, total: 100)))
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                return .init(
                    content: [.text(
                        text: "Progress test completed", annotations: nil, _meta: nil)],
                    isError: false, resultType: .complete)

            case "test_missing_capability":
                // Refused at dispatch rather than part-way through. A tool that will need to
                // sample cannot run for a client that cannot sample, and discovering that after
                // the work is done means the work cannot be delivered.
                guard parameters._meta?.clientCapabilities?.sampling != nil else {
                    throw MCPError.missingRequiredClientCapability(requiring: ["sampling"])
                }
                return .init(
                    content: [.text(
                        text: "Sampling capability was declared", annotations: nil, _meta: nil)],
                    isError: false, resultType: .complete)

            case "test_sampling":
            // The pre-2026 channel: the server asks the client mid-request and waits. Removed by
            // 2026-07-28 in favour of SEP-2322 — a client on this revision retries with its
            // answers instead — and kept because this package still serves earlier revisions,
            // where this is the only mechanism there is.
            guard let server else {
                throw MCPError.internalError("The server went away mid-request")
            }
            let prompt = parameters.arguments?["prompt"]?.stringValue ?? ""
            let sampled = try await server.requestSampling(
                messages: [.user(.text(prompt))], maxTokens: 100)
            return .init(
                content: [.text(
                    text: "LLM response: \(Self.text(of: sampled))", annotations: nil,
                    _meta: nil)],
                isError: false, resultType: .complete)

        case "test_elicitation":
            guard let server else {
                throw MCPError.internalError("The server went away mid-request")
            }
            let message = parameters.arguments?["message"]?.stringValue ?? ""
            let answered = try await server.requestElicitation(
                message: message,
                requestedSchema: .init(
                    properties: [
                        "username": .object([
                            "type": .string("string"),
                            "description": .string("User's response"),
                        ]),
                        "email": .object([
                            "type": .string("string"),
                            "description": .string("User's email address"),
                        ]),
                    ]))
            return .init(
                content: [.text(
                    text: "User responded: \(answered.action.rawValue)", annotations: nil,
                    _meta: nil)],
                isError: false, resultType: .complete)

        case "test_elicitation_sep1034_defaults", "test_elicitation_sep1330_enums":
            guard let server else {
                throw MCPError.internalError("The server went away mid-request")
            }
            let schema = parameters.name == "test_elicitation_sep1034_defaults"
                ? Fixtures.defaultsSchema
                : Fixtures.enumVariantsSchema
            let answered = try await server.requestElicitation(
                message: "Please fill this in", requestedSchema: schema)
            let content = answered.content?.mapValues { "\($0)" } ?? [:]
            return .init(
                content: [.text(
                    text: "Elicitation completed: action=\(answered.action.rawValue), "
                        + "content=\(content.keys.sorted())",
                    annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)

        case "test_trigger_tool_change", "test_trigger_prompt_change":
            // The notification goes to the open `subscriptions/listen` streams, not to the
            // response stream of this call: a list changing is a fact about the server, not
            // about the request that happened to cause it, and a client that is not subscribed
            // has not asked to hear about it.
            let method = parameters.name == "test_trigger_tool_change"
                ? "notifications/tools/list_changed"
                : "notifications/prompts/list_changed"
            await streams?.broadcast(method: method)
            return .init(
                content: [.text(text: "Mutated the list", annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)

        case "test_logging_tool":
            // SEP-2575 removed `logging/setLevel`: a request asks for logs per-call, in
            // `_meta`. A server that logs regardless is sending a client output it did not ask
            // for on a stream it is reading for its result.
            if parameters._meta?.logLevel != nil {
                try await server?.notify(
                    LogMessageNotification.message(
                        .init(level: .info, data: .string("test_logging_tool ran"))))
            }
            return .init(
                content: [.text(text: "Logging tool completed", annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)

        case "test_streaming_elicitation":
            return .init(
                content: [.text(
                    text: "Streaming elicitation completed", annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)

        case "test_custom_headers":
            // Reached only once the transport has checked the header against this argument, so
            // echoing it is a statement that the two agreed.
            let region = parameters.arguments?["region"]?.stringValue ?? ""
            return .init(
                content: [.text(text: "Region: \(region)", annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)

        case "greet":
                let who = parameters.arguments?["name"]?.stringValue ?? "world"
                return .init(
                    content: [.text(text: "Hello, \(who)!", annotations: nil, _meta: nil)],
                    isError: false, resultType: .complete)

            case "json_schema_2020_12_tool":
                return .init(
                    content: [.text(
                        text: "This is a simple text response for testing.", annotations: nil,
                        _meta: nil)],
                    isError: false, resultType: .complete)

        default:
            throw MCPError.invalidParams("Unknown tool: \(parameters.name)")
        }
    }

    /// The text a sampling result carries, whichever content shape it used.
    ///
    /// - Parameter result: The client's sampled message.
    /// - Returns: The first text block, or an empty string.
    private static func text(of result: CreateSamplingMessage.Result) -> String {
        let blocks: [Sampling.Message.Content.ContentBlock]
        switch result.content {
        case .single(let block): blocks = [block]
        case .multiple(let many): blocks = many
        }
        for block in blocks {
            if case .text(let text) = block { return text }
        }
        return ""
    }

    // MARK: - Prompts

    private static func registerPrompts(on server: Server) async {
        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(
                prompts: Fixtures.prompts + InputRequiredFixtures.prompts, resultType: .complete, ttlMs: 60_000,
                cacheScope: .public)
        }

        await server.withMethodHandler(MRTRGetPrompt.self) { parameters in
            // SEP-2322 is not a tools feature: `prompts/get` can need input too, and this
            // prompt exists to prove it. Same either-shape problem as `tools/call`, so the same
            // `Value`-returning treatment.
            if parameters.name == "test_input_required_result_prompt" {
                switch InputRequiredFixtures.respondToPrompt(responses: parameters.inputResponses) {
                case .needsInput(let interim):
                    return try encodeValue(interim)
                case .complete(let text):
                    return try encodeValue(GetPrompt.Result(
                        description: "A prompt that asked for context",
                        messages: [.user(.text(text: text))], resultType: .complete))
                }
            }

            guard let prompt = Fixtures.promptMessages(
                named: parameters.name, arguments: parameters.arguments)
            else {
                throw MCPError.invalidParams("Unknown prompt: \(parameters.name)")
            }
            return try encodeValue(GetPrompt.Result(
                description: prompt.description, messages: prompt.messages,
                resultType: .complete))
        }
    }

    /// `prompts/get`, seen as a method that may answer with either a prompt or a request for
    /// input. Same reasoning as ``TasksSurface``'s call handler: a typed handler returns one
    /// shape, and SEP-2322 needs two.
    private enum MRTRGetPrompt: MCP.Method {
        static let name = GetPrompt.name
        typealias Parameters = GetPrompt.Parameters
        typealias Result = Value
    }

    /// Renders a typed result as the `Value` an either-shape handler returns.
    ///
    /// - Parameter result: The result to render.
    /// - Returns: The same result, as a JSON value.
    static func encodeValue(_ result: some Encodable) throws -> Value {
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    // MARK: - Resources

    private static func registerResources(
        on server: Server, subscriptions: SubscriptionState
    ) async {
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(
                resources: Fixtures.resources, resultType: .complete, ttlMs: 60_000,
                cacheScope: .public)
        }

        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(
                templates: Fixtures.resourceTemplates, resultType: .complete, ttlMs: 60_000,
                cacheScope: .public)
        }

        await server.withMethodHandler(ReadResource.self) { parameters in
            guard let contents = Fixtures.resourceContents(for: parameters.uri) else {
                // SEP-2164: the URI travels in `data`, so a client reading several resources at
                // once can tell which read was refused.
                throw MCPError.resourceNotFound(uri: parameters.uri)
            }
            return ReadResource.Result(
                contents: contents, resultType: .complete, ttlMs: 60_000, cacheScope: .public)
        }

        await server.withMethodHandler(ResourceSubscribe.self) { parameters in
            await subscriptions.subscribe(to: parameters.uri)
            return Empty()
        }

        await server.withMethodHandler(ResourceUnsubscribe.self) { parameters in
            await subscriptions.unsubscribe(from: parameters.uri)
            return Empty()
        }
    }

    // MARK: - Utilities

    private static func registerUtilities(on server: Server) async {
        await server.withMethodHandler(SetLoggingLevel.self) { _ in Empty() }

        await server.withMethodHandler(Complete.self) { parameters in
            // Completions over the prompt arguments this server declares. The suite asks for a
            // response of the right shape; answering from the real fixtures rather than a fixed
            // list keeps this from drifting away from what is registered above.
            let candidates = Fixtures.prompts.flatMap { $0.arguments ?? [] }.map(\.name)
            let prefix = parameters.argument.value
            let matches = candidates.filter { $0.hasPrefix(prefix) }.sorted()
            return Complete.Result(
                completion: .init(values: matches, total: matches.count, hasMore: false))
        }

        await server.withMethodHandler(SubscriptionsListen.self) { _ in
            SubscriptionsListen.Result(resultType: .complete)
        }
    }
}
