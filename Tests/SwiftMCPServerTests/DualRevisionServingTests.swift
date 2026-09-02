import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer
import MCP

/// The acceptance criteria for serving MCP `2026-07-28` alongside earlier revisions.
///
/// A `2026-07-28` client completes `server/discover` → `tools/list` → `tools/call` with **no
/// `initialize` handshake and no `Mcp-Session-Id`**, while a `2025-03-26` client completes the
/// same work unchanged. Both must hold at once; either alone is not the goal.
@Suite("Dual Revision Serving")
struct DualRevisionServingTests {

    /// Stand up a real MCP server on `port`, wired to the HTTP transport.
    ///
    /// The transport alone only opens a listener; without a `Server` pumping it, a JSON-RPC
    /// request is registered as pending and never answered. These tests exercise the whole
    /// path, so they need both.
    private func startServer(port: UInt16) async throws -> (HTTPServerTransport, Server) {
        let transport = HTTPServerTransport(port: port)
        let server = Server(
            name: "acceptance-server",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [], resultType: .complete, ttlMs: 60_000, cacheScope: .public)
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
        await server.withMethodHandler(SubscriptionsListen.self) { _ in
            SubscriptionsListen.Result(resultType: .complete)
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        return (transport, server)
    }

    /// The routing headers a 2026-07-28 client sends alongside its body.
    ///
    /// SEP-2243 makes `Mcp-Method` — and `Mcp-Name`, where a body names a tool, prompt or
    /// resource — required on that revision, so a frame posted without them is refused before it
    /// reaches whatever a test is actually about. Supplied here rather than in each test for the
    /// same reason `Content-Type` is: it is what a client always sends, not the subject.
    ///
    /// A caller that passes either header explicitly keeps its own value, including the wrong
    /// ones the mismatch tests depend on.
    private func routingHeaders(
        for body: [String: Any], overriding supplied: [String: String]
    ) -> [String: String] {
        let meta = (body["_meta"] as? [String: Any])
            ?? ((body["params"] as? [String: Any])?["_meta"] as? [String: Any])
        guard meta?["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28",
              let method = body["method"] as? String
        else { return [:] }

        let alreadySupplied = Set(supplied.keys.map { $0.lowercased() })
        var headers: [String: String] = [:]
        if !alreadySupplied.contains("mcp-method") { headers["Mcp-Method"] = method }

        let params = body["params"] as? [String: Any]
        let nameShaped = (params?["name"] as? String) ?? (params?["uri"] as? String)
        if let nameShaped, !alreadySupplied.contains("mcp-name") {
            headers["Mcp-Name"] = nameShaped
        }
        return headers
    }

    /// POST a frame and return both the HTTP status and the decoded body.
    private func postWithStatus(
        _ body: [String: Any],
        to port: UInt16,
        headers: [String: String] = [:]
    ) async throws -> (status: Int, json: [String: Any]) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/mcp"
        let url = try #require(components.url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in routingHeaders(for: body, overriding: headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// POST a JSON-RPC frame and return the decoded response body.
    private func post(
        _ body: [String: Any],
        to port: UInt16,
        headers: [String: String] = [:]
    ) async throws -> [String: Any] {
        // Assembled field by field rather than interpolated into a string: `port` then cannot
        // widen into a host or a scheme, which is what the SSRF check is guarding against.
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/mcp"
        let url = try #require(components.url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in routingHeaders(for: body, overriding: headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json ?? [:]
    }

    /// A request as a 2026-07-28 client sends it: protocol version and client capabilities
    /// declared per-request in `_meta`, no session id, no prior handshake.
    private func statelessFrame(id: Int, method: String, params: [String: Any] = [:]) -> [String: Any] {
        var frame: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "_meta": [
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": [:],
                "io.modelcontextprotocol/clientInfo": ["name": "acceptance", "version": "1.0.0"],
            ],
        ]
        if !params.isEmpty { frame["params"] = params }
        return frame
    }

    @Test("A 2026-07-28 client works with no initialize and no session id")
    func test2026ClientNeedsNoHandshake() async throws {
        let (transport, _) = try await startServer(port: 9210)
        defer { Task { await transport.disconnect() } }

        // server/discover — MUST be implemented, and is the compatibility probe.
        let discover = try await post(statelessFrame(id: 1, method: "server/discover"), to: 9210)
        let discoverResult = try #require(discover["result"] as? [String: Any])
        let versions = try #require(discoverResult["supportedVersions"] as? [String])
        #expect(versions.contains("2026-07-28"), "discovery must advertise the current revision")

        // tools/list — no session id was ever issued, and none is sent.
        let list = try await post(statelessFrame(id: 2, method: "tools/list"), to: 9210)
        #expect(list["error"] == nil, "a stateless request must not be refused")
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [Any])
        #expect(tools.isEmpty, "the acceptance server registers no tools")
        #expect(listResult["resultType"] as? String == "complete")
        #expect(listResult["ttlMs"] as? Int == 60_000)
        #expect(listResult["cacheScope"] as? String == "public")
    }

    @Test("A 2025-03-26 client still completes the initialize flow unchanged")
    func test2025ClientUnchanged() async throws {
        let (transport, _) = try await startServer(port: 9211)
        defer { Task { await transport.disconnect() } }

        let initialize = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": ["name": "legacy", "version": "1.0.0"],
            ],
        ], to: 9211)

        let result = try #require(initialize["result"] as? [String: Any])
        let negotiated = try #require(result["protocolVersion"] as? String)
        #expect(
            negotiated == "2025-03-26",
            "an older client must keep its own revision, not be pushed to the latest")
        #expect(initialize["error"] == nil)
    }

    /// `Mcp-Method` must agree with the body. A mismatch is a routing bug or a tampered
    /// request, and the specification requires `400` with code `-32020` rather than answering
    /// whichever one happened to win.
    @Test("A request whose Mcp-Method disagrees with its body is refused")
    func testHeaderMismatchIsRefused() async throws {
        let (transport, _) = try await startServer(port: 9213)
        defer { Task { await transport.disconnect() } }

        let response = try await post(
            statelessFrame(id: 1, method: "tools/list"),
            to: 9213,
            headers: ["Mcp-Method": "tools/call"]
        )

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020, "a header mismatch is -32020")
    }

    /// A matching header must be accepted, so a conforming 2026-07-28 client is not penalised
    /// for sending what the specification requires.
    @Test("A request whose Mcp-Method agrees with its body is served")
    func testMatchingHeaderIsServed() async throws {
        let (transport, _) = try await startServer(port: 9214)
        defer { Task { await transport.disconnect() } }

        let response = try await post(
            statelessFrame(id: 1, method: "tools/list"),
            to: 9214,
            headers: ["Mcp-Method": "tools/list"]
        )

        #expect(response["error"] == nil)
        let result = try #require(response["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [Any])
        #expect(tools.isEmpty, "a matching header must be served the same result as no header")
    }

    /// A client on an earlier revision sends no such header and must not be refused for it.
    @Test("A request without the header is still served")
    func testAbsentHeaderIsTolerated() async throws {
        let (transport, _) = try await startServer(port: 9215)
        defer { Task { await transport.disconnect() } }

        let response = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list",
        ], to: 9215)

        #expect(response["error"] == nil, "an earlier-revision client sends no Mcp-Method")
    }

    /// Claude Code re-initializes on every health check. Before adopted upstream PR #257 made
    /// `initialize` idempotent, the second call errored with "Server is already initialized" and
    /// `HTTPServerTransport.send()` fabricated a synthetic success to hide it — hardcoding
    /// `2025-03-26` and a frozen capability block.
    ///
    /// This test is the evidence for removing that workaround: a repeated `initialize` must
    /// succeed on its own, and must answer with the same negotiated version both times.
    @Test("A repeated initialize succeeds without a synthetic response")
    func testRepeatedInitializeIsIdempotent() async throws {
        let (transport, _) = try await startServer(port: 9216)
        defer { Task { await transport.disconnect() } }

        func initialize(id: Int) async throws -> [String: Any] {
            try await post([
                "jsonrpc": "2.0", "id": id, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-03-26",
                    "capabilities": [:],
                    "clientInfo": ["name": "health-check", "version": "1.0.0"],
                ],
            ], to: 9216)
        }

        let first = try await initialize(id: 1)
        let second = try await initialize(id: 2)

        #expect(first["error"] == nil, "the first initialize must succeed")
        #expect(second["error"] == nil, "a repeated initialize must not error")

        let firstVersion = try #require((first["result"] as? [String: Any])?["protocolVersion"] as? String)
        let secondVersion = try #require((second["result"] as? [String: Any])?["protocolVersion"] as? String)
        #expect(
            firstVersion == secondVersion,
            "both answers must negotiate the same revision — the synthetic response did not")
        #expect(firstVersion == "2025-03-26")
    }

    /// The acknowledgement is the first event on the stream, and states the subset the server
    /// will actually honour. This package registers no resource source, so a client asking for
    /// resource notifications must be told it will not get them — a client told nothing waits
    /// for updates that can never arrive, which is worse than being declined.
    @Test("The acknowledgement is the first event and narrows what was requested")
    func testSubscriptionsListenAcknowledges() async throws {
        let (transport, _) = try await startServer(port: 9217)
        defer { Task { await transport.disconnect() } }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = 9217
        components.path = "/mcp"
        let url = try #require(components.url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("subscriptions/listen", forHTTPHeaderField: "Mcp-Method")
        var frame = statelessFrame(id: 1, method: "subscriptions/listen")
        frame["params"] = ["notifications": ["toolsListChanged": true, "resourcesListChanged": true]]
        request.httpBody = try JSONSerialization.data(withJSONObject: frame)

        let session = URLSession(configuration: .ephemeral)
        let (stream, response) = try await session.bytes(for: request)
        defer { session.invalidateAndCancel() }

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true)

        // Read only the first data line; the stream stays open by design.
        var acknowledgement: [String: Any]?
        for try await line in stream.lines where line.hasPrefix("data: ") {
            let payload = String(line.dropFirst("data: ".count))
            acknowledgement = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            break
        }

        let ack = try #require(acknowledgement, "no acknowledgement arrived on the stream")
        #expect(ack["method"] as? String == "notifications/subscriptions/acknowledged")

        let params = try #require(ack["params"] as? [String: Any])
        let honoured = try #require(params["notifications"] as? [String: Any])
        #expect(honoured["toolsListChanged"] as? Bool == true, "tool changes are honoured")
        #expect(
            honoured["resourcesListChanged"] == nil,
            "no resource source exists, so the server must not claim it")

        // The subscription id is what lets a client attribute later notifications, so it must
        // be a usable identifier rather than merely present.
        let meta = try #require(params["_meta"] as? [String: Any])
        let subscriptionId = try #require(
            meta["io.modelcontextprotocol/subscriptionId"] as? String)
        #expect(!subscriptionId.isEmpty)
        // Unwrapped rather than null-checked: the id must actually parse as a UUID, which is
        // what makes it opaque and unguessable rather than merely non-empty.
        _ = try #require(UUID(uuidString: subscriptionId), "the id should be an opaque UUID")
    }

    /// `Mcp-Name` mirrors `params.name` (or `params.uri`) so an intermediary can route without
    /// parsing the body. A disagreement means the router and the executor are working from
    /// different values, which is the vulnerability the check exists to close.
    @Test("A request whose Mcp-Name disagrees with its body is refused")
    func testMcpNameMismatchRefused() async throws {
        let (transport, _) = try await startServer(port: 9218)
        defer { Task { await transport.disconnect() } }

        var frame = statelessFrame(id: 1, method: "tools/call")
        frame["params"] = ["name": "get_weather", "arguments": [:]]

        let response = try await post(
            frame, to: 9218,
            headers: ["Mcp-Method": "tools/call", "Mcp-Name": "something_else"])

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }

    /// A name outside the header-safe ASCII set arrives Base64-encoded in a sentinel. The server
    /// must decode before comparing, or every non-ASCII tool name would look like a mismatch.
    @Test("A Base64-encoded Mcp-Name is decoded before comparison")
    func testBase64EncodedMcpNameMatches() async throws {
        let (transport, _) = try await startServer(port: 9219)
        defer { Task { await transport.disconnect() } }

        let toolName = "get_wéather"
        let encoded = "=?base64?" + Data(toolName.utf8).base64EncodedString() + "?="

        var frame = statelessFrame(id: 1, method: "tools/call")
        frame["params"] = ["name": toolName, "arguments": [:]]

        let response = try await post(
            frame, to: 9219,
            headers: ["Mcp-Method": "tools/call", "Mcp-Name": encoded])

        let error = response["error"] as? [String: Any]
        #expect(error?["code"] as? Int != -32020, "an encoded name that matches must not be a mismatch")
    }

    /// `MCP-Protocol-Version` must agree with the version declared in the body's `_meta`.
    @Test("A protocol version header disagreeing with _meta is refused")
    func testProtocolVersionHeaderMismatchRefused() async throws {
        let (transport, _) = try await startServer(port: 9220)
        defer { Task { await transport.disconnect() } }

        let response = try await post(
            statelessFrame(id: 1, method: "tools/list"), to: 9220,
            headers: ["MCP-Protocol-Version": "2025-03-26"])  // body declares 2026-07-28

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }

    /// An agreeing header must be served, and a client on an earlier revision sends none at all.
    @Test("Agreeing and absent protocol version headers are both served")
    func testProtocolVersionHeaderAgreeingOrAbsent() async throws {
        let (transport, _) = try await startServer(port: 9221)
        defer { Task { await transport.disconnect() } }

        let agreeing = try await post(
            statelessFrame(id: 1, method: "tools/list"), to: 9221,
            headers: ["MCP-Protocol-Version": "2026-07-28"])
        #expect(agreeing["error"] == nil)

        let absent = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], to: 9221)
        #expect(absent["error"] == nil, "an earlier-revision client sends no such header")
    }

    /// A 2026-07-28 request **MUST** carry `protocolVersion` and `clientCapabilities` in `_meta`.
    /// One that does not is malformed, and the server must answer `-32602` with HTTP 400 — not
    /// guess at the missing values, which would be inventing the client's capabilities.
    @Test("A 2026 request missing required _meta fields is refused", arguments: [
        "clientCapabilities", "protocolVersion",
    ])
    func testMissingRequiredMetaRefused(omitted: String) async throws {
        // Parameterised cases run in parallel, so each needs its own port or the second fails
        // to bind rather than failing its assertion.
        let port: UInt16 = omitted == "protocolVersion" ? 9222 : 9224
        let (transport, _) = try await startServer(port: port)
        defer { Task { await transport.disconnect() } }

        var meta: [String: Any] = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]
        meta.removeValue(forKey: "io.modelcontextprotocol/\(omitted)")

        let response = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "_meta": meta,
        ], to: port)

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602, "a malformed request is invalid params")
    }

    /// A request declaring an earlier revision carries no such `_meta`, and must not be judged
    /// by 2026 rules — that is what keeps one server able to answer both.
    @Test("An earlier-revision request without _meta is still served")
    func testEarlierRevisionWithoutMetaServed() async throws {
        let (transport, _) = try await startServer(port: 9223)
        defer { Task { await transport.disconnect() } }

        let response = try await post(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], to: 9223)

        #expect(response["error"] == nil, "no declared version means pre-2026 rules apply")
    }

    /// An unimplemented method must answer `404` with `-32601`. That JSON-RPC body is what lets
    /// a client tell a modern server from a legacy one during its fallback probe: a bare 404
    /// means "not an MCP endpoint", a 404 carrying -32601 means "MCP endpoint, no such method".
    @Test("An unknown method answers 404 with -32601")
    func testUnknownMethodIs404() async throws {
        let (transport, _) = try await startServer(port: 9225)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await postWithStatus(
            statelessFrame(id: 1, method: "nonexistent/method"), to: 9225)

        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601, "method not found")
        #expect(status == 404, "the HTTP status distinguishes a modern server from a legacy one")
    }

    /// Issue a bare GET or DELETE and return the status.
    private func request(
        method: String, path: String, to port: UInt16, headers: [String: String] = [:]
    ) async throws -> Int {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = path
        let url = try #require(components.url)

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// 2026-07-28 removed the standalone GET stream and session termination, so a client on that
    /// revision must be told the method is not allowed rather than served a mechanism the
    /// revision does not have.
    @Test("GET and DELETE are refused for a 2026-07-28 client", arguments: ["GET", "DELETE"])
    func testGetAndDeleteRefusedFor2026(method: String) async throws {
        let port: UInt16 = method == "GET" ? 9226 : 9227
        let (transport, _) = try await startServer(port: port)
        defer { Task { await transport.disconnect() } }

        let status = try await request(
            method: method, path: "/mcp", to: port,
            headers: ["MCP-Protocol-Version": "2026-07-28"])
        #expect(status == 405, "\(method) is not part of this revision")
    }

    /// A client on an earlier revision legitimately uses both, and must keep working — the
    /// refusal is conditional on the declared revision, not unconditional.
    @Test("DELETE still works for a client that declares no 2026 version")
    func testDeleteStillWorksForEarlierRevision() async throws {
        let (transport, _) = try await startServer(port: 9228)
        defer { Task { await transport.disconnect() } }

        let status = try await request(method: "DELETE", path: "/mcp", to: 9228)
        #expect(status != 405, "an earlier-revision client may still terminate a session")
    }

    /// 2026-07-28 removed `initialize`, `ping`, `logging/setLevel` and the subscribe pair. A
    /// client on that revision must be told they do not exist — `404` with `-32601` — rather
    /// than served a mechanism its revision dropped.
    ///
    /// Found by the official conformance suite, which reported HTTP 200 where it required 404.
    /// It is an external tool that will not run in CI, so the behaviour is pinned here.
    @Test("Methods removed in 2026-07-28 answer 404 for a client on that revision", arguments: [
        ("initialize", UInt16(9230)),
        ("ping", UInt16(9231)),
        ("logging/setLevel", UInt16(9232)),
        ("resources/subscribe", UInt16(9233)),
        ("resources/unsubscribe", UInt16(9234)),
    ])
    func testRemovedMethodsRefusedFor2026(method: String, port: UInt16) async throws {
        // Each parameterised case needs its own port: they run in parallel, and a hashed port
        // collided — the case then failed to bind rather than failing its assertion.
        let (transport, _) = try await startServer(port: port)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await postWithStatus(
            statelessFrame(id: 1, method: method), to: port)

        #expect(status == 404, "\(method) was removed in this revision")
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    /// The same methods must keep working for a client that declares no 2026 version — that
    /// conditionality is the whole basis of serving both revisions from one implementation.
    @Test("initialize still works for a client on an earlier revision")
    func testInitializeStillWorksForEarlierRevision() async throws {
        let (transport, _) = try await startServer(port: 9251)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await postWithStatus([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26", "capabilities": [:],
                "clientInfo": ["name": "legacy", "version": "1.0.0"],
            ],
        ], to: 9251)

        #expect(status == 200, "an earlier-revision client may still initialize")
        #expect(response["error"] == nil)
    }

    /// An unsupported version is refused with `-32022` and the versions this server does
    /// support, so the client can choose one rather than guess.
    @Test("An unsupported protocol version is refused with the supported set")
    func testUnsupportedVersionRefused() async throws {
        let (transport, _) = try await startServer(port: 9252)
        defer { Task { await transport.disconnect() } }

        var frame: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list",
            "_meta": [
                "io.modelcontextprotocol/protocolVersion": "2030-01-01",
                "io.modelcontextprotocol/clientCapabilities": [:],
            ],
        ]
        frame["params"] = [:]

        let (status, response) = try await postWithStatus(frame, to: 9252)

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32022)

        // The supported set must be carried, or the client has been told "no" with no way
        // forward — which is what the error exists to prevent.
        let data = try #require(error["data"] as? [String: Any])
        let supported = try #require(data["supported"] as? [String])
        #expect(supported.contains("2026-07-28"))
        #expect(supported.count >= 2, "more than one revision is supported")
    }

    /// Discovery must declare what the server actually handles. A client on this revision has no
    /// handshake to correct the picture — discovery is the only thing it can ask — so declaring
    /// a capability that is not served, or omitting one that is, both mislead it.
    @Test("Discovery declares only the capabilities actually served")
    func testDiscoveryDeclaresWhatIsServed() async throws {
        let (transport, _) = try await startServer(port: 9253)
        defer { Task { await transport.disconnect() } }

        let discover = try await post(statelessFrame(id: 1, method: "server/discover"), to: 9253)
        let result = try #require(discover["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])

        // The acceptance harness registers tools only. Unwrapped rather than null-checked, so
        // the declaration has to be a real object rather than merely present.
        _ = try #require(capabilities["tools"] as? [String: Any], "tools are served and must be declared")
        #expect(
            capabilities["resources"] == nil,
            "no resource provider is registered, so resources must not be declared")
    }

    @Test("Discovery advertises only versions the server will actually negotiate")
    func testDiscoveryIsHonest() async throws {
        let (transport, _) = try await startServer(port: 9212)
        defer { Task { await transport.disconnect() } }

        let discover = try await post(statelessFrame(id: 1, method: "server/discover"), to: 9212)
        let result = try #require(discover["result"] as? [String: Any])
        let versions = try #require(result["supportedVersions"] as? [String])

        for version in versions {
            #expect(
                Version.supported.contains(version),
                "\(version) is advertised but the SDK would not negotiate it")
        }
    }
}
