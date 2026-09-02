import Crypto
import Foundation
import MCP
import SwiftMCPServer

/// The Multi Round-Trip Request fixtures (SEP-2322).
///
/// A server that needs something from the client — a value from the user, a sample from a model,
/// the client's roots — cannot simply call back: `2026-07-28` is stateless and has no channel
/// for it. So it answers with `resultType: "input_required"`, names what it needs, and the
/// client **retries the original request** with the answers attached. The retry is the
/// continuation; there is no `continue` method.
///
/// `requestState` is what makes that affordable: the server hands the client an opaque token
/// carrying whatever it wants to remember, rather than keeping a session for a conversation that
/// may never resume.
public enum InputRequiredFixtures {

    /// The tools that gather input before they answer.
    public static let tools: [Tool] = [
        "test_input_required_result_elicitation",
        "test_input_required_result_sampling",
        "test_input_required_result_list_roots",
        "test_input_required_result_request_state",
        "test_input_required_result_multiple_inputs",
        "test_input_required_result_multi_round",
        "test_input_required_result_tampered_state",
        "test_input_required_result_capabilities",
    ].map {
        Tool(
            name: $0, description: "Gathers input before it can answer (SEP-2322)",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]))
    }

    /// The prompt that does the same, proving the mechanism is not a tools feature.
    public static let prompts: [Prompt] = [
        Prompt(
            name: "test_input_required_result_prompt",
            description: "A prompt that asks the user what context to use")
    ]

    /// Whether this fixture set owns `name`.
    ///
    /// - Parameter name: A tool name.
    /// - Returns: `true` when this file answers for it.
    public static func handles(_ name: String) -> Bool {
        tools.contains { $0.name == name }
    }

    // MARK: - The individual requests

    private static func elicitation(
        message: String, property: String, type: String = "string"
    ) -> InputRequest {
        .elicit(.form(.init(
            message: message,
            requestedSchema: .init(
                properties: [property: .object(["type": .string(type)])],
                required: [property]))))
    }

    private static func sampling(_ prompt: String, maxTokens: Int) -> InputRequest {
        .createMessage(.init(messages: [.user(.text(prompt))], maxTokens: maxTokens))
    }

    /// The question `test_tool_with_task` asks before it escalates.
    ///
    /// Exposed because that fixture lives on the tasks surface — the two SEPs compose there, and
    /// the question has to be the same one in both places or the answer will not match the key.
    public static var nameQuestion: InputRequest {
        elicitation(message: "What is your name?", property: "name")
    }

    /// The name a client supplied through ``nameQuestion``.
    ///
    /// - Parameter response: The client's answer.
    /// - Returns: The name, or `nil` if the user declined or sent something unusable.
    public static func elicitedName(from response: InputResponse) -> String? {
        elicitedString(response, key: "name")
    }

    // MARK: - Rounds

    /// What a tool answers, given whatever the client has supplied so far.
    ///
    /// - Parameters:
    ///   - name: The tool being called.
    ///   - responses: Answers the client attached, if any.
    ///   - requestState: The state the client echoed back, if any.
    ///   - capabilities: What the client said it can do.
    /// - Returns: Either the next round's questions, or the finished result.
    public static func respond(
        to name: String,
        responses: [String: InputResponse]?,
        requestState: String?,
        capabilities: Client.Capabilities?
    ) throws -> MRTRAnswer {
        switch name {
        case "test_input_required_result_elicitation":
            guard let answer = responses?["user_name"] else {
                return .needsInput(.init(inputRequests: [
                    "user_name": elicitation(message: "What is your name?", property: "name")
                ]))
            }
            // A wrong or unusable answer re-asks rather than erroring: SEP-2322 says the server
            // SHOULD re-request, and a JSON-RPC error would tell the client the call is dead
            // when one more round would finish it.
            guard let name = elicitedString(answer, key: "name") else {
                return .needsInput(.init(inputRequests: [
                    "user_name": elicitation(message: "What is your name?", property: "name")
                ]))
            }
            return .complete(text: "Hello, \(name)!")

        case "test_input_required_result_sampling":
            guard let answer = responses?["capital_question"] else {
                return .needsInput(.init(inputRequests: [
                    "capital_question": sampling(
                        "What is the capital of France?", maxTokens: 100)
                ]))
            }
            return .complete(text: "The model said: \(sampledText(answer) ?? "nothing")")

        case "test_input_required_result_list_roots":
            guard let answer = responses?["client_roots"] else {
                return .needsInput(.init(inputRequests: ["client_roots": .listRoots(Empty())]))
            }
            guard case .listRoots(let roots) = answer else {
                return .needsInput(.init(inputRequests: ["client_roots": .listRoots(Empty())]))
            }
            return .complete(text: "Client reported \(roots.roots.count) roots")

        case "test_input_required_result_request_state":
            let questions: [String: InputRequest] = [
                "confirm": elicitation(message: "Please confirm", property: "ok", type: "boolean")
            ]
            guard responses?["confirm"] != nil else {
                return .needsInput(.init(
                    inputRequests: questions, requestState: try RequestState.issue("confirm")))
            }
            // The word the scenario reads back, and it is only reachable through a state that
            // verified — which is the whole assertion.
            try RequestState.verify(requestState, expecting: "confirm")
            return .complete(text: "state-ok: confirmed")

        case "test_input_required_result_multiple_inputs":
            let questions: [String: InputRequest] = [
                "user_name": elicitation(message: "What is your name?", property: "name"),
                "greeting": sampling("Generate a greeting", maxTokens: 50),
                "client_roots": .listRoots(Empty()),
            ]
            let answered = Set(responses?.keys ?? [:].keys)
            let outstanding = questions.filter { !answered.contains($0.key) }
            guard outstanding.isEmpty else {
                return .needsInput(.init(
                    inputRequests: outstanding,
                    requestState: try RequestState.issue("multiple")))
            }
            try RequestState.verify(requestState, expecting: "multiple")
            return .complete(text: "Received all \(questions.count) answers")

        case "test_input_required_result_multi_round":
            // Which round this is comes from the state the client echoed, not from a counter
            // here: the server keeps nothing between rounds, which is the point of the token.
            // An absent token is round one. A *present* token that will not verify is a
            // different thing — a tampered or stale continuation — and is refused rather than
            // quietly restarted, which would hide it.
            let round: String
            if requestState == nil {
                round = ""
            } else {
                round = try RequestState.stage(of: requestState)
            }
            if round.isEmpty || responses?["step1"] == nil, round != "step2" {
                return .needsInput(.init(
                    inputRequests: [
                        "step1": elicitation(
                            message: "Step 1: What is your name?", property: "name")
                    ],
                    requestState: try RequestState.issue("step1")))
            }
            if round == "step1" {
                return .needsInput(.init(
                    inputRequests: [
                        "step2": elicitation(
                            message: "Step 2: What is your favorite color?", property: "color")
                    ],
                    requestState: try RequestState.issue("step2")))
            }
            try RequestState.verify(requestState, expecting: "step2")
            return .complete(text: "state-ok: both steps answered")

        case "test_input_required_result_tampered_state":
            guard responses?["confirm"] != nil else {
                return .needsInput(.init(
                    inputRequests: [
                        "confirm": elicitation(
                            message: "Please confirm", property: "ok", type: "boolean")
                    ],
                    requestState: try RequestState.issue("tamper")))
            }
            // Signed, so a modified token is detected rather than trusted. A server that
            // accepted whatever came back would be letting the client rewrite the server's own
            // memory of the exchange.
            try RequestState.verify(requestState, expecting: "tamper")
            return .complete(text: "state-ok: signature verified")

        case "test_input_required_result_capabilities":
            // Only ask for what the client said it can do. Asking a client to elicit when it
            // declared no elicitation capability guarantees a round that cannot be answered.
            var questions: [String: InputRequest] = [:]
            if capabilities?.sampling != nil {
                questions["capital_question"] = sampling(
                    "What is the capital of France?", maxTokens: 100)
            }
            if capabilities?.elicitation != nil {
                questions["user_name"] = elicitation(
                    message: "What is your name?", property: "name")
            }
            let answered = Set(responses?.keys ?? [:].keys)
            let outstanding = questions.filter { !answered.contains($0.key) }
            guard outstanding.isEmpty else {
                return .needsInput(.init(inputRequests: outstanding))
            }
            return .complete(text: "Asked only for declared capabilities")

        default:
            throw MCPError.invalidParams("Unknown input-required tool: \(name)")
        }
    }

    /// The prompt's rounds, which follow the same rule as the tools'.
    ///
    /// - Parameter responses: Answers the client attached, if any.
    /// - Returns: The next round's questions, or the finished messages.
    public static func respondToPrompt(
        responses: [String: InputResponse]?
    ) -> MRTRAnswer {
        guard let answer = responses?["user_context"],
            let context = elicitedString(answer, key: "context")
        else {
            return .needsInput(.init(inputRequests: [
                "user_context": elicitation(
                    message: "What context should the prompt use?", property: "context")
            ]))
        }
        return .complete(text: "Prompt using context: \(context)")
    }

    // MARK: - Reading answers

    /// A string the user supplied through an elicitation.
    private static func elicitedString(_ response: InputResponse, key: String) -> String? {
        guard case .elicit(let result) = response, result.action == .accept else { return nil }
        return result.content?[key]?.stringValue
    }

    /// The text a model produced through a sampling request.
    ///
    /// A sampling result carries either one block or several; only the text is wanted here, so
    /// both shapes are flattened to the first text block rather than special-cased at the two
    /// call sites.
    private static func sampledText(_ response: InputResponse) -> String? {
        guard case .createMessage(let result) = response else { return nil }
        let blocks: [Sampling.Message.Content.ContentBlock]
        switch result.content {
        case .single(let block): blocks = [block]
        case .multiple(let many): blocks = many
        }
        for block in blocks {
            if case .text(let text) = block { return text }
        }
        return nil
    }
}

/// What a round of a multi-round request answers with.
public enum MRTRAnswer: Sendable {
    /// The server still needs something before it can finish.
    case needsInput(InputRequiredResult)
    /// The server is done.
    case complete(text: String)
}

/// The opaque token a server hands a client between rounds.
///
/// Signed, because the client holds it and hands it back: the specification calls it opaque, and
/// a server that trusts whatever returns is letting the client rewrite the server's own memory
/// of the exchange. The signature is what turns "the client should not modify this" into
/// something the server can check.
enum RequestState {
    /// A per-process key. The token only has to outlive the exchange, and a key that does not
    /// outlive the process cannot leak into one.
    private static let key = SymmetricKey(size: .bits256)

    /// Issues a signed token naming which round comes next.
    ///
    /// - Parameter stage: What the server wants to remember.
    /// - Returns: The token to hand the client.
    static func issue(_ stage: String) throws -> String {
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stage.utf8), using: key)
        return "\(stage).\(Data(signature).base64EncodedString())"
    }

    /// The stage a token names, if its signature holds.
    ///
    /// - Parameter token: The token the client echoed back.
    /// - Returns: The stage it names.
    static func stage(of token: String?) throws -> String {
        guard let token, let separator = token.lastIndex(of: ".") else {
            throw MCPError.invalidParams("requestState is missing or malformed")
        }
        let stage = String(token[token.startIndex..<separator])
        let supplied = String(token[token.index(after: separator)...])
        guard let signature = Data(base64Encoded: supplied),
            HMAC<SHA256>.isValidAuthenticationCode(
                signature, authenticating: Data(stage.utf8), using: key)
        else {
            throw MCPError.invalidParams("requestState failed its integrity check")
        }
        return stage
    }

    /// Checks that a token is intact and names the round the server expected.
    ///
    /// - Parameters:
    ///   - token: The token the client echoed back.
    ///   - expected: The stage the server issued.
    static func verify(_ token: String?, expecting expected: String) throws {
        guard try stage(of: token) == expected else {
            throw MCPError.invalidParams("requestState names a different round")
        }
    }
}
