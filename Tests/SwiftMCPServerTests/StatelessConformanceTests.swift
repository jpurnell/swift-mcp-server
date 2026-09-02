import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer
import MCP

/// The behaviours the official MCP conformance suite's `server-stateless` and
/// `http-header-validation` scenarios require, pinned as tests here so they can fail in seconds
/// rather than only under a Node harness.
///
/// Each test names the conformance check it stands in for. When one of these regresses, the
/// suite regresses with it — that correspondence is the point, and is what stops the suite from
/// being the only place a rule is written down.
@Suite("Stateless Conformance")
struct StatelessConformanceTests {

    /// Stand up a real server with one tool, so `tools/call` has something to name.
    private func startServer(
        port: UInt16, allowedHosts: AllowedHosts = .any
    ) async throws -> (HTTPServerTransport, Server) {
        let transport = HTTPServerTransport(port: port, allowedHosts: allowedHosts)
        let server = Server(
            name: "stateless-conformance",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        let echo = Tool(
            name: "echo",
            description: "Returns what it is given.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [echo], resultType: .complete, ttlMs: 60_000, cacheScope: .public)
        }
        await server.withMethodHandler(CallTool.self) { _ in
            CallTool.Result(
                content: [.text(text: "ok", annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)
        }
        await server.withMethodHandler(Discover.self) { _ in
            Discover.Result(
                supportedVersions: Version.supported.sorted(by: >),
                capabilities: .init(tools: .init(listChanged: false)),
                resultType: .complete,
                ttlMs: 3_600_000,
                cacheScope: .public
            )
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        return (transport, server)
    }

    /// POST a frame and return the HTTP status alongside the decoded body.
    private func post(
        _ body: [String: Any],
        to port: UInt16,
        headers: [String: String] = [:],
        host: String? = nil
    ) async throws -> (status: Int, json: [String: Any]) {
        // Assembled field by field rather than interpolated, so `port` cannot widen into a host.
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/mcp"
        let url = try #require(components.url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// A 2026-07-28 request: version and capabilities declared per-request, no session.
    private func frame(
        id: Int, method: String, params: [String: Any]? = nil, version: String = "2026-07-28"
    ) -> [String: Any] {
        var params = params ?? [:]
        params["_meta"] = [
            "io.modelcontextprotocol/protocolVersion": version,
            "io.modelcontextprotocol/clientCapabilities": [:],
            "io.modelcontextprotocol/clientInfo": ["name": "conformance-client", "version": "1.0.0"],
        ]
        return ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    /// The `Origin` a browser on this machine would send for a page served by this server.
    ///
    /// Assembled from its parts rather than written as a literal, for the same reason the request
    /// URL is: a port interpolated into a string can widen into a host.
    private func originForLocalhost(port: UInt16) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        return components.string ?? ""
    }

    /// The headers a 2026-07-28 client sends alongside a body, mirroring it for routing.
    private func routingHeaders(method: String, name: String? = nil) -> [String: String] {
        var headers = ["Mcp-Method": method, "MCP-Protocol-Version": "2026-07-28"]
        if let name { headers["Mcp-Name"] = name }
        return headers
    }

    // MARK: - Version negotiation

    /// Conformance check `HttpServerHeaderMismatch400`.
    ///
    /// A header carrying a version the body does not is a *mismatch* — the two layers disagree —
    /// and stays a mismatch even when the header's value is also a version this server never
    /// serves. Reporting `-32022` there tells the client to renegotiate when the actual fault is
    /// that its router and its body were built from different values, which renegotiating will
    /// not fix.
    @Test("A mismatched version header is a mismatch, not an unsupported version")
    func testHeaderMismatchOutranksUnsupportedVersion() async throws {
        let (transport, _) = try await startServer(port: 9320)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            frame(id: 1, method: "tools/list"), to: 9320,
            headers: ["Mcp-Method": "tools/list", "MCP-Protocol-Version": "v999.0.0"])

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020, "the layers disagree; that is the fault to report")
    }

    /// Conformance check `ServerUnsupportedVersionError`.
    ///
    /// `supported` alone leaves the client to work out which of its own attempts was refused
    /// when several are in flight. Echoing `requested` makes the error self-describing.
    @Test("An unsupported version error echoes the version that was requested")
    func testUnsupportedVersionEchoesRequested() async throws {
        let (transport, _) = try await startServer(port: 9321)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            frame(id: 1, method: "tools/list", version: "v999.0.0"), to: 9321)

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32022)
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["requested"] as? String == "v999.0.0")
        #expect((data["supported"] as? [String])?.contains("2026-07-28") == true)
    }

    // MARK: - Required per-request metadata

    /// Conformance checks `RequestMetaInvalid` and `HttpServerMetaInvalid400`.
    ///
    /// `server/discover` exists only in 2026-07-28, so a request reaching it is on that revision
    /// whether or not it says so — there is no earlier client to protect. Its `_meta` is how the
    /// server learns the client's version and capabilities, and a request without it has told
    /// the server nothing it can safely act on.
    @Test("A 2026-only method with no _meta at all is refused")
    func testMissingMetaOnRevisionOnlyMethodRefused() async throws {
        let (transport, _) = try await startServer(port: 9322)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            ["jsonrpc": "2.0", "id": 101, "method": "server/discover", "params": [:]],
            to: 9322)

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
        #expect(response["id"] as? Int == 101, "an error must carry the id it answers")
    }

    /// A request on an earlier revision carries none of this and must still be served, which is
    /// the whole reason the rule is scoped to methods that only 2026-07-28 defines.
    @Test("An earlier-revision method with no _meta is still served")
    func testMissingMetaOnSharedMethodStillServed() async throws {
        let (transport, _) = try await startServer(port: 9323)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], to: 9323)

        #expect(status == 200)
        #expect(response["error"] == nil, "tools/list predates the _meta requirement")
    }

    // MARK: - Routing headers

    /// Conformance check `ServerRejectsMissingMethodHeader`.
    ///
    /// SEP-2243 makes `Mcp-Method` required, not optional-but-checked. A missing header is the
    /// same failure as a wrong one from an intermediary's point of view: it cannot route, and
    /// the request must not be silently executed as though it could.
    @Test("A 2026-07-28 request with no Mcp-Method header is refused")
    func testMissingMethodHeaderRefused() async throws {
        let (transport, _) = try await startServer(port: 9324)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            frame(id: 101, method: "tools/list"), to: 9324,
            headers: ["MCP-Protocol-Version": "2026-07-28"])

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }

    /// Conformance check `ServerRejectsMissingNameHeader`.
    @Test("A tools/call naming a tool in its body but not its header is refused")
    func testMissingNameHeaderRefused() async throws {
        let (transport, _) = try await startServer(port: 9325)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            frame(id: 104, method: "tools/call", params: ["name": "echo", "arguments": [:]]),
            to: 9325,
            headers: routingHeaders(method: "tools/call"))

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }

    /// Conformance check `ServerAcceptsWhitespaceHeaderValue`.
    ///
    /// RFC 9110 §5.5 puts optional whitespace around a field value outside the value itself. A
    /// server that compares the raw bytes rejects a request every intermediary is entitled to
    /// send.
    @Test("Whitespace around a header value is not part of the value")
    func testHeaderValueWhitespaceTrimmed() async throws {
        let (transport, _) = try await startServer(port: 9326)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            frame(id: 103, method: "tools/call", params: ["name": "echo", "arguments": [:]]),
            to: 9326,
            headers: routingHeaders(method: "tools/call", name: "  echo  "))

        #expect(status == 200)
        #expect(response["error"] == nil, "OWS is not part of the field value")
    }

    /// A missing `Mcp-Method` on an earlier revision is not a fault — that revision has no such
    /// header — so the requirement must not leak backwards.
    @Test("An earlier-revision request needs no routing headers")
    func testEarlierRevisionNeedsNoRoutingHeaders() async throws {
        let (transport, _) = try await startServer(port: 9327)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]], to: 9327)

        #expect(status == 200)
        #expect(response["error"] == nil)
    }

    /// Conformance check `Sep2663ServerRejectsMismatchedMcpNameOnTasksGet`.
    ///
    /// SEP-2663 extends SEP-2243's routing headers to the tasks surface: on `tasks/get`,
    /// `tasks/update` and `tasks/cancel`, `Mcp-Name` mirrors `params.taskId`. Same reasoning as
    /// for a tool name — an intermediary routes on the header, and a header naming a different
    /// task than the body means the router and the executor are working from different values.
    @Test("A tasks request whose Mcp-Name disagrees with its taskId is refused", arguments: [
        ("tasks/get", UInt16(9332)), ("tasks/update", UInt16(9333)),
        ("tasks/cancel", UInt16(9334)),
    ])
    func testTaskNameHeaderMismatchRefused(method: String, port: UInt16) async throws {
        let (transport, _) = try await startServer(port: port)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            frame(id: 1, method: method, params: ["taskId": "task-1"]), to: port,
            headers: routingHeaders(method: method, name: "a-different-task"))

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }

    /// An agreeing header must be served — the requirement is that they match, not that the
    /// header is absent.
    @Test("A tasks request whose Mcp-Name matches its taskId is not a mismatch")
    func testTaskNameHeaderAgreeing() async throws {
        let (transport, _) = try await startServer(port: 9335)
        defer { Task { await transport.disconnect() } }

        let (_, response) = try await post(
            frame(id: 1, method: "tasks/get", params: ["taskId": "task-1"]), to: 9335,
            headers: routingHeaders(method: "tasks/get", name: "task-1"))

        let error = response["error"] as? [String: Any]
        #expect(error?["code"] as? Int != -32020, "the header agrees with the body")
    }

    /// Conformance check `TasksRemovedTasksResult`.
    ///
    /// SEP-2243 enumerates the methods `Mcp-Name` applies to; it is not "any request with a
    /// name-shaped field". Requiring it more widely means a method the server does not implement
    /// is refused for a missing header instead of answered `-32601`, and the client is told its
    /// routing is wrong when the truth is that the method does not exist.
    @Test("A method outside the routing-header rules is not refused for lacking Mcp-Name")
    func testUnlistedMethodNeedsNoName() async throws {
        let (transport, _) = try await startServer(port: 9336)
        defer { Task { await transport.disconnect() } }

        // `tasks/result` was removed in v2. It carries a taskId, and it is not one of the
        // methods the header rules name.
        let (status, response) = try await post(
            frame(id: 1, method: "tasks/result", params: ["taskId": "task-1"]), to: 9336,
            headers: ["Mcp-Method": "tasks/result", "MCP-Protocol-Version": "2026-07-28"])

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601, "the method does not exist; say that")
        #expect(status == 404)
    }

    // MARK: - Client capabilities

    /// Conformance checks `ServerRejectsUndeclaredCapability` and `MissingCapabilityHttp400`.
    ///
    /// A tool that will need to sample cannot run for a client that cannot sample. Discovering
    /// that halfway through means the work is already done and cannot be delivered, so the
    /// refusal belongs at dispatch — and it names what was missing, as a capability object, so
    /// the client can declare it and retry rather than guess.
    @Test("A tool needing an undeclared client capability is refused")
    func testUndeclaredClientCapabilityRefused() async throws {
        let transport = HTTPServerTransport(port: 9328)
        let server = Server(
            name: "capability-conformance", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false)))
        let tool = Tool(
            name: "test_missing_capability",
            description: "Requires the sampling client capability.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [tool], resultType: .complete, ttlMs: 60_000, cacheScope: .public)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            let declared = parameters._meta?.clientCapabilities
            guard declared?.sampling != nil else {
                throw MCPError.missingRequiredClientCapability(requiring: ["sampling"])
            }
            return CallTool.Result(
                content: [.text(text: "ran", annotations: nil, _meta: nil)],
                isError: false, resultType: .complete)
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            frame(id: 401, method: "tools/call",
                  params: ["name": "test_missing_capability", "arguments": [:]]),
            to: 9328,
            headers: routingHeaders(method: "tools/call", name: "test_missing_capability"))

        #expect(status == 400, "the transport must map -32021 onto a 400")
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32021)

        // A ClientCapabilities object keyed by the missing capability, not a list of names: the
        // client can merge it into what it already declares.
        let data = try #require(error["data"] as? [String: Any])
        let required = try #require(data["requiredCapabilities"] as? [String: Any])
        #expect(Array(required.keys) == ["sampling"], "only the capability actually needed")
        let sampling = try #require(required["sampling"] as? [String: Any])
        #expect(sampling.isEmpty, "the value says which capability, not how to configure it")
    }

    // MARK: - Host and Origin

    /// Conformance check `DNSRebindingRejected`.
    ///
    /// A page on an attacker's origin can make a browser resolve that name to `127.0.0.1` and
    /// then POST to a server that only ever expected local callers. The request arrives looking
    /// local at the socket and foreign in its headers, and the headers are the only place the
    /// difference is visible.
    @Test("A request claiming a foreign Host is refused")
    func testDNSRebindingRefused() async throws {
        let (transport, _) = try await startServer(port: 9329, allowedHosts: .loopback)
        defer { Task { await transport.disconnect() } }

        let (status, _) = try await post(
            frame(id: 1, method: "server/discover"), to: 9329,
            headers: ["Origin": "https://evil.example.com", "Mcp-Method": "server/discover"],
            host: "evil.example.com")

        #expect(status >= 400 && status < 500, "a foreign Host must not be served")
    }

    /// The guard must not refuse the callers it exists to serve.
    @Test("A local caller is served")
    func testLocalhostAccepted() async throws {
        let (transport, _) = try await startServer(port: 9330, allowedHosts: .loopback)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await post(
            frame(id: 1, method: "server/discover"), to: 9330,
            headers: ["Origin": originForLocalhost(port: 9330), "Mcp-Method": "server/discover"])

        #expect(status == 200)
        #expect(response["error"] == nil)
    }

    // MARK: - Server identity

    /// Conformance check `ServerIdentifiesInResultMeta`.
    ///
    /// A stateless client never sees an `initialize` result, so discovery is the only place it
    /// can learn who answered. Spec PR #3002 puts that in the result's `_meta`.
    @Test("Discovery identifies the server in the result _meta")
    func testDiscoverCarriesServerInfo() async throws {
        let (transport, _) = try await startServer(port: 9331)
        defer { Task { await transport.disconnect() } }

        let (_, response) = try await post(
            frame(id: 1, method: "server/discover"), to: 9331,
            headers: routingHeaders(method: "server/discover"))

        let result = try #require(response["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        let info = try #require(meta["io.modelcontextprotocol/serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "stateless-conformance")
        #expect(info["version"] as? String == "1.0.0")
    }
}

extension StatelessConformanceTests {
    /// Conformance check `ServerHonorsNotificationFilter`.
    ///
    /// A subscription names what it wants. Delivering more than that is not generosity — the
    /// client asked for a filter because it is not prepared to handle the rest, and a stream
    /// that ignores the filter makes the acknowledgement it sent a lie.
    @Test("A notification kind a stream did not subscribe to is not delivered to it")
    func testNotificationFilterHonoured() async throws {
        let registry = SubscriptionStreamRegistry()
        let promptsOnly = RecordingConnection()
        let everything = RecordingConnection()

        await registry.register(
            SSESession(connection: promptsOnly), id: "prompts-only",
            honouring: ["promptsListChanged"])
        await registry.register(
            SSESession(connection: everything), id: "everything",
            honouring: ["promptsListChanged", "toolsListChanged"])

        await registry.broadcast(method: "notifications/tools/list_changed")

        // `sendEvent` hands the write to a detached Task, so the broadcast returning means
        // "dispatched", not "delivered". Waiting for the stream that *should* receive it is
        // what makes the assertion about the other one meaningful — otherwise an empty
        // recording would pass whether the filter worked or the write simply had not happened.
        var delivered = 0
        for _ in 0..<100 {
            delivered = await everything.written.count
            if delivered > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(delivered == 1, "the stream that subscribed to tool changes receives it")
        #expect(
            await promptsOnly.written.isEmpty,
            "this stream asked for prompt changes and nothing else")
    }
}

/// A connection that remembers what was written to it.
actor RecordingConnection: HTTPConnection {
    private(set) var written: [Data] = []

    nonisolated let id = UUID().uuidString
    nonisolated let remoteAddress = "test"
    var isActive: Bool { true }

    func send(_ data: Data) async throws {
        written.append(data)
    }

    func sendSSEHead(headers: [(String, String)]) async {}

    func close() async {}
}
