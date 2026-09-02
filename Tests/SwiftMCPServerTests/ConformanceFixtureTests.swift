import ConformanceFixtures
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer
import MCP

/// The official conformance suite's own assertions, made here instead.
///
/// The suite is a Node harness that has to be installed, pinned to an alpha version, and pointed
/// at a running process — which makes it a thing you remember to run rather than a thing that
/// runs. Every assertion it makes about a fixture is reproducible over plain HTTP, so it is made
/// here as well, against ``ConformanceTarget`` — the *same* server the harness drives, not a
/// second one built to resemble it.
///
/// That correspondence is the point. When one of these fails, the suite fails; when the suite
/// finds something these miss, the finding belongs here before it is fixed.
@Suite("Conformance Fixtures")
struct ConformanceFixtureTests {

    /// Stand up the conformance target on `port`.
    private func startTarget(port: UInt16) async throws -> HTTPServerTransport {
        let transport = HTTPServerTransport(
            port: port, allowedHosts: .loopback, tools: ConformanceTarget.tools,
            subscribableNotifications: ConformanceTarget.subscribableNotifications)
        let server = await ConformanceTarget.makeServer(
            subscriptions: SubscriptionState(), streams: transport.subscriptionStreams)
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        return transport
    }

    /// POST a JSON-RPC frame the way a 2026-07-28 client does, and decode the result.
    private func call(
        _ method: String, params: [String: Any] = [:], to port: UInt16, id: Int = 1
    ) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/mcp"
        let url = try #require(components.url)

        var params = params
        params["_meta"] = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": [:],
            "io.modelcontextprotocol/clientInfo": ["name": "conformance-client", "version": "1.0.0"],
        ]
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        // SEP-2243 mirrors the body's name-shaped field into a header on this revision.
        if let name = (params["name"] as? String) ?? (params["uri"] as? String) {
            request.setValue(name, forHTTPHeaderField: "Mcp-Name")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// The `result` of a call, failing the test rather than the decode if it errored.
    private func result(
        _ method: String, params: [String: Any] = [:], to port: UInt16
    ) async throws -> [String: Any] {
        let response = try await call(method, params: params, to: port)
        if let error = response["error"] as? [String: Any] {
            Issue.record("\(method) answered an error: \(error)")
        }
        return try #require(response["result"] as? [String: Any])
    }

    /// The content blocks of a `tools/call` result.
    private func callTool(
        _ name: String, to port: UInt16, arguments: [String: Any] = [:]
    ) async throws -> (content: [[String: Any]], isError: Bool) {
        let result = try await result(
            "tools/call", params: ["name": name, "arguments": arguments], to: port)
        let content = try #require(result["content"] as? [[String: Any]])
        return (content, result["isError"] as? Bool ?? false)
    }

    // MARK: - The fixture surface

    /// The suite calls each of these by name. A target missing one reports "1 passed, 1 failed"
    /// for that whole scenario, which reads as a protocol failure and is not one — so the roster
    /// is asserted directly rather than inferred from the scenarios that happen to be written.
    @Test("tools/list exposes every fixture the suite calls by name")
    func testFixtureToolsAreRegistered() async throws {
        let transport = try await startTarget(port: 9340)
        defer { Task { await transport.disconnect() } }

        let result = try await result("tools/list", to: 9340)
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        for required in [
            "test_simple_text", "test_image_content", "test_audio_content",
            "test_embedded_resource", "test_multiple_content_types", "test_error_handling",
            "test_tool_with_logging", "test_tool_with_progress", "test_missing_capability",
            "json_schema_2020_12_tool", "greet",
        ] {
            #expect(names.contains(required), "the suite calls \(required) by name")
        }
    }

    /// SEP-2549: a client cannot cache what it is not told the lifetime of, and these are the
    /// results the specification names.
    // Parameterised cases run in parallel, so each carries its own port. Derived from the
    // argument rather than listed, two of them once hashed to the same number and the second
    // failed to bind instead of failing its assertion.
    @Test("Cacheable results carry ttlMs and cacheScope", arguments: [
        ("tools/list", UInt16(9341)), ("prompts/list", UInt16(9342)),
        ("resources/list", UInt16(9343)), ("resources/templates/list", UInt16(9344)),
    ])
    func testCachingHints(method: String, port: UInt16) async throws {
        let transport = try await startTarget(port: port)
        defer { Task { await transport.disconnect() } }

        let result = try await result(method, to: port)
        let ttl = try #require(result["ttlMs"] as? Int, "\(method) must say how long it is fresh")
        #expect(ttl >= 0)
        #expect(["public", "private"].contains(result["cacheScope"] as? String ?? ""))
    }

    /// Conformance scenario `json-schema-2020-12` (SEP-1613, SEP-2106).
    ///
    /// A schema type that models only the keywords it understands silently drops the rest, and
    /// the loss is invisible until a client tries to validate against what it was given. These
    /// are the keywords the suite reads back one at a time, so the assertion is that each
    /// survives the round trip — not that the schema is well-formed.
    @Test("A 2020-12 input schema survives the round trip keyword for keyword")
    func testJSONSchemaKeywordsPreserved() async throws {
        let transport = try await startTarget(port: 9364)
        defer { Task { await transport.disconnect() } }

        let result = try await result("tools/list", to: 9364)
        let tools = try #require(result["tools"] as? [[String: Any]])
        let tool = try #require(tools.first { $0["name"] as? String == "json_schema_2020_12_tool" })
        let schema = try #require(tool["inputSchema"] as? [String: Any])

        #expect(schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
        #expect(schema["additionalProperties"] as? Bool == false)

        // SEP-2106: composition and conditional vocabularies. Asserted by content rather than
        // by presence — a schema type that rebuilt these keywords as empty objects would satisfy
        // "not nil" while having lost everything they said.
        let allOf = try #require(schema["allOf"] as? [[String: Any]])
        let anyOf = try #require(allOf.first?["anyOf"] as? [[String: Any]])
        #expect(anyOf.compactMap { ($0["required"] as? [String])?.first } == ["phone", "email"])

        let conditional = try #require(schema["if"] as? [String: Any])
        let conditionalProperties = try #require(conditional["properties"] as? [String: Any])
        let contactMethod = try #require(conditionalProperties["contactMethod"] as? [String: Any])
        #expect(contactMethod["const"] as? String == "phone")
        #expect((schema["then"] as? [String: Any])?["required"] as? [String] == ["phone"])
        #expect((schema["else"] as? [String: Any])?["required"] as? [String] == ["email"])

        // The anchor lives inside $defs, which is where a shallow copy tends to lose it.
        let defs = try #require(schema["$defs"] as? [String: Any])
        let address = try #require(defs["address"] as? [String: Any])
        #expect(address["$anchor"] as? String == "addressDef")

        // And the reference that points at it.
        let properties = try #require(schema["properties"] as? [String: Any])
        let addressProperty = try #require(properties["address"] as? [String: Any])
        #expect(addressProperty["$ref"] as? String == "#/$defs/address")
    }

    // MARK: - Tool content kinds

    @Test("test_simple_text returns text content")
    func testSimpleText() async throws {
        let transport = try await startTarget(port: 9345)
        defer { Task { await transport.disconnect() } }

        let (content, isError) = try await callTool("test_simple_text", to: 9345)
        #expect(!isError)
        let text = try #require(content.first { $0["type"] as? String == "text" })
        #expect(text["text"] as? String == "This is a simple text response for testing.")
    }

    @Test("test_image_content returns image content with its mime type")
    func testImageContent() async throws {
        let transport = try await startTarget(port: 9346)
        defer { Task { await transport.disconnect() } }

        let (content, _) = try await callTool("test_image_content", to: 9346)
        let image = try #require(content.first { $0["type"] as? String == "image" })
        #expect(image["mimeType"] as? String == "image/png")
        let data = try #require(image["data"] as? String)
        // Decoded rather than compared to a constant: the assertion is that what arrived is a
        // PNG, not that it matches a string this test also declares.
        let bytes = try #require(Data(base64Encoded: data))
        #expect(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), "a PNG signature")
    }

    @Test("test_audio_content returns audio content with its mime type")
    func testAudioContent() async throws {
        let transport = try await startTarget(port: 9347)
        defer { Task { await transport.disconnect() } }

        let (content, _) = try await callTool("test_audio_content", to: 9347)
        let audio = try #require(content.first { $0["type"] as? String == "audio" })
        #expect(audio["mimeType"] as? String == "audio/wav")
        let encoded = try #require(audio["data"] as? String)
        let bytes = try #require(Data(base64Encoded: encoded))
        #expect(bytes.starts(with: Array("RIFF".utf8)), "a RIFF/WAVE header")
    }

    @Test("test_embedded_resource returns a resource block")
    func testEmbeddedResource() async throws {
        let transport = try await startTarget(port: 9348)
        defer { Task { await transport.disconnect() } }

        let (content, _) = try await callTool("test_embedded_resource", to: 9348)
        let block = try #require(content.first { $0["type"] as? String == "resource" })
        let resource = try #require(block["resource"] as? [String: Any])
        #expect(resource["uri"] as? String == "test://embedded-resource")
        #expect(resource["text"] as? String == "This is an embedded resource content.")
    }

    @Test("test_multiple_content_types returns text, image and resource together")
    func testMixedContent() async throws {
        let transport = try await startTarget(port: 9349)
        defer { Task { await transport.disconnect() } }

        let (content, _) = try await callTool("test_multiple_content_types", to: 9349)
        let kinds = content.compactMap { $0["type"] as? String }
        #expect(kinds == ["text", "image", "resource"], "in the order the scenario expects")
    }

    /// A tool that ran and reported a failure is a *result*, not a protocol fault: the JSON-RPC
    /// response succeeds and carries `isError`. Answering with a JSON-RPC error instead would
    /// tell the client the call never happened.
    @Test("test_error_handling reports isError on a successful response")
    func testToolError() async throws {
        let transport = try await startTarget(port: 9350)
        defer { Task { await transport.disconnect() } }

        let response = try await call(
            "tools/call", params: ["name": "test_error_handling", "arguments": [:]], to: 9350)
        #expect(response["error"] == nil, "a tool error is not a protocol error")

        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(!content.isEmpty, "an error still says what went wrong")
    }

    /// Conformance check `ServerRejectsUndeclaredCapability`, driven through the real fixture
    /// rather than a stand-in, so the diagnostic tool the suite looks for is the one under test.
    @Test("test_missing_capability refuses a client that did not declare sampling")
    func testMissingCapabilityRefused() async throws {
        let transport = try await startTarget(port: 9351)
        defer { Task { await transport.disconnect() } }

        let response = try await call(
            "tools/call", params: ["name": "test_missing_capability", "arguments": [:]], to: 9351)

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32021)
        let data = try #require(error["data"] as? [String: Any])
        let required = try #require(data["requiredCapabilities"] as? [String: Any])
        #expect(Array(required.keys) == ["sampling"], "only the capability actually needed")
        let sampling = try #require(required["sampling"] as? [String: Any])
        #expect(sampling.isEmpty, "the value says which capability, not how to configure it")
    }

    /// The fixtures for mechanisms `2026-07-28` removed. They are registered because this
    /// package still serves earlier revisions; a client on `2025-11-25` has no other way to be
    /// asked something mid-request.
    @Test("The pre-2026 sampling and elicitation fixtures are still registered")
    func testLegacyFixturesAreRegistered() async throws {
        let transport = try await startTarget(port: 9365)
        defer { Task { await transport.disconnect() } }

        let result = try await result("tools/list", to: 9365)
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        for required in [
            "test_sampling", "test_elicitation",
            "test_elicitation_sep1034_defaults", "test_elicitation_sep1330_enums",
        ] {
            #expect(names.contains(required))
        }
    }

    /// SEP-1034: a default for every primitive type, so a client can render the form filled in
    /// and a user can accept without typing.
    @Test("The defaults schema carries a default for each primitive type")
    func testElicitationDefaultsSchema() throws {
        let properties = Fixtures.defaultsSchema.properties

        #expect(properties["name"]?.objectValue?["default"]?.stringValue == "John Doe")
        #expect(properties["age"]?.objectValue?["default"]?.intValue == 30)
        // Bit-identical, not approximate: this default is carried, never computed, so anything
        // short of unchanged is a defect rather than drift.
        let score = try #require(properties["score"]?.objectValue?["default"]?.doubleValue)
        #expect(score.bitPattern == (95.5 as Double).bitPattern)
        #expect(properties["status"]?.objectValue?["default"]?.stringValue == "active")
        #expect(properties["verified"]?.objectValue?["default"]?.boolValue == true)
    }

    /// SEP-1330 defines five enum shapes, and the three single-select ones differ only in how a
    /// label is carried — not at all, in `oneOf` with a `title`, or in the deprecated parallel
    /// `enumNames`. A client has to handle each, so the fixture offers all three.
    @Test("The enum schema offers all five variants the specification defines")
    func testElicitationEnumVariants() throws {
        let properties = Fixtures.enumVariantsSchema.properties
        #expect(
            Set(properties.keys) == [
                "untitledSingle", "titledSingle", "legacyEnum", "untitledMulti", "titledMulti",
            ])

        let untitled = try #require(properties["untitledSingle"]?.objectValue)
        #expect(untitled["enum"]?.arrayValue?.count == 3)

        let titled = try #require(properties["titledSingle"]?.objectValue)
        let choices = try #require(titled["oneOf"]?.arrayValue)
        #expect(choices.first?.objectValue?["title"]?.stringValue == "First Option")

        let legacy = try #require(properties["legacyEnum"]?.objectValue)
        #expect(legacy["enumNames"]?.arrayValue?.count == 3, "the deprecated parallel array")

        let multi = try #require(properties["untitledMulti"]?.objectValue)
        #expect(multi["type"]?.stringValue == "array")
    }

    // MARK: - Prompts

    @Test("prompts/list exposes every prompt the suite calls by name")
    func testFixturePromptsAreRegistered() async throws {
        let transport = try await startTarget(port: 9352)
        defer { Task { await transport.disconnect() } }

        let result = try await result("prompts/list", to: 9352)
        let prompts = try #require(result["prompts"] as? [[String: Any]])
        let names = Set(prompts.compactMap { $0["name"] as? String })

        for required in [
            "test_simple_prompt", "test_prompt_with_arguments",
            "test_prompt_with_embedded_resource", "test_prompt_with_image",
        ] {
            #expect(names.contains(required))
        }
    }

    @Test("test_simple_prompt returns its one message")
    func testSimplePrompt() async throws {
        let transport = try await startTarget(port: 9353)
        defer { Task { await transport.disconnect() } }

        let result = try await result(
            "prompts/get", params: ["name": "test_simple_prompt"], to: 9353)
        let messages = try #require(result["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        let content = try #require(messages.first?["content"] as? [String: Any])
        #expect(content["text"] as? String == "This is a simple prompt for testing.")
    }

    /// The arguments have to reach the message, which is the only thing this scenario tests and
    /// the one thing a hardcoded reply would fake.
    @Test("test_prompt_with_arguments substitutes what it was given")
    func testPromptWithArguments() async throws {
        let transport = try await startTarget(port: 9354)
        defer { Task { await transport.disconnect() } }

        let result = try await result(
            "prompts/get",
            params: ["name": "test_prompt_with_arguments",
                     "arguments": ["arg1": "hello", "arg2": "world"]],
            to: 9354)
        let messages = try #require(result["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [String: Any])
        #expect(content["text"] as? String == "Prompt with arguments: arg1='hello', arg2='world'")
    }

    @Test("test_prompt_with_embedded_resource embeds the URI it was handed")
    func testPromptWithEmbeddedResource() async throws {
        let transport = try await startTarget(port: 9355)
        defer { Task { await transport.disconnect() } }

        let result = try await result(
            "prompts/get",
            params: ["name": "test_prompt_with_embedded_resource",
                     "arguments": ["resourceUri": "test://caller-chosen"]],
            to: 9355)
        let messages = try #require(result["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        let content = try #require(messages.first?["content"] as? [String: Any])
        let resource = try #require(content["resource"] as? [String: Any])
        #expect(resource["uri"] as? String == "test://caller-chosen", "the caller's URI, not ours")
    }

    @Test("test_prompt_with_image returns an image message and a text message")
    func testPromptWithImage() async throws {
        let transport = try await startTarget(port: 9356)
        defer { Task { await transport.disconnect() } }

        let result = try await result(
            "prompts/get", params: ["name": "test_prompt_with_image"], to: 9356)
        let messages = try #require(result["messages"] as? [[String: Any]])
        let kinds = messages.compactMap { ($0["content"] as? [String: Any])?["type"] as? String }
        #expect(kinds == ["image", "text"])
    }

    // MARK: - Resources

    @Test("resources/read returns the text resource's contents")
    func testReadTextResource() async throws {
        let transport = try await startTarget(port: 9357)
        defer { Task { await transport.disconnect() } }

        let result = try await result(
            "resources/read", params: ["uri": "test://static-text"], to: 9357)
        let contents = try #require(result["contents"] as? [[String: Any]])
        let first = try #require(contents.first)
        #expect(first["mimeType"] as? String == "text/plain")
        #expect(first["text"] as? String == "This is the content of the static text resource.")
    }

    @Test("resources/read returns the binary resource as a blob")
    func testReadBinaryResource() async throws {
        let transport = try await startTarget(port: 9358)
        defer { Task { await transport.disconnect() } }

        let result = try await result(
            "resources/read", params: ["uri": "test://static-binary"], to: 9358)
        let contents = try #require(result["contents"] as? [[String: Any]])
        let first = try #require(contents.first)
        #expect(first["text"] == nil, "binary content travels as a blob, not as text")
        let encoded = try #require(first["blob"] as? String)
        let bytes = try #require(Data(base64Encoded: encoded))
        #expect(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    /// The template's parameter must reach the content, or the server is answering a fixed
    /// resource under a URI that only looks parameterised.
    @Test("A templated URI substitutes its parameter")
    func testReadTemplatedResource() async throws {
        let transport = try await startTarget(port: 9359)
        defer { Task { await transport.disconnect() } }

        let result = try await result(
            "resources/read", params: ["uri": "test://template/123/data"], to: 9359)
        let contents = try #require(result["contents"] as? [[String: Any]])
        let first = try #require(contents.first)
        #expect(first["uri"] as? String == "test://template/123/data")
        let text = try #require(first["text"] as? String)
        #expect(text.contains("\"id\":\"123\""), "the id the caller asked for")
        #expect(text.contains("Data for ID: 123"))
    }

    /// Conformance checks `ResourcesNotFoundErrorCode` and `ResourcesNotFoundDataUri` (SEP-2164).
    ///
    /// An empty `contents` array says "this resource is empty", which is a different claim from
    /// "there is no such resource" — and a client cannot tell them apart.
    @Test("An unknown resource is refused, with the URI it refused")
    func testUnknownResourceRefused() async throws {
        let transport = try await startTarget(port: 9360)
        defer { Task { await transport.disconnect() } }

        let uri = "test://nonexistent-resource-for-conformance-testing"
        let response = try await call("resources/read", params: ["uri": uri], to: 9360)

        #expect(response["result"] == nil, "an absent resource is not an empty one")
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["uri"] as? String == uri)
    }

    /// A URI that resembles the template but does not match it must not be answered: a template
    /// that accepts more than it describes answers for resources the server does not have.
    @Test("A near-miss on the template is refused", arguments: [
        ("test://template//data", UInt16(9361)),
        ("test://template/1/data/extra", UInt16(9362)),
        ("test://template/1", UInt16(9363)),
    ])
    func testTemplateNearMissRefused(uri: String, port: UInt16) async throws {
        let transport = try await startTarget(port: port)
        defer { Task { await transport.disconnect() } }

        let response = try await call("resources/read", params: ["uri": uri], to: port)
        let error = try #require(response["error"] as? [String: Any], "\(uri) is not a resource")
        #expect(error["code"] as? Int == -32602)
    }

    // MARK: - The fixtures themselves

    /// The roster is also checked without a server, so a fixture that was renamed out from under
    /// the suite fails immediately rather than through an HTTP round trip.
    @Test("Every declared resource can actually be read")
    func testDeclaredResourcesAreReadable() throws {
        for resource in Fixtures.resources {
            let contents = Fixtures.resourceContents(for: resource.uri)
            #expect(contents?.isEmpty == false, "\(resource.uri) is listed but has no contents")
        }
    }

    /// Every prompt `prompts/list` advertises must answer `prompts/get`.
    @Test("Every declared prompt can actually be fetched")
    func testDeclaredPromptsAreFetchable() throws {
        for prompt in Fixtures.prompts {
            let arguments = Dictionary(
                uniqueKeysWithValues: (prompt.arguments ?? []).map { ($0.name, "value") })
            let messages = Fixtures.promptMessages(named: prompt.name, arguments: arguments)
            #expect(messages?.messages.isEmpty == false, "\(prompt.name) is listed but empty")
        }
    }
}
