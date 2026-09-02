import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer
import MCP

/// SEP-2243's custom `x-mcp-header` parameters.
///
/// A tool may declare that one of its arguments is *also* carried in a named HTTP header, so an
/// intermediary can route or authorise on it without parsing the body. The same reasoning as
/// `Mcp-Name`, generalised: whatever the header says and whatever the body says must be the same
/// thing, or the router and the executor are working from different values.
///
/// Only the sentinel form is decoded. A value that merely resembles Base64 is a literal — a
/// server that guessed would mangle any argument that happened to look encoded.
@Suite("Custom header parameters")
struct CustomHeaderParameterTests {

    /// The annotation names the parameter; the wire header is `Mcp-Param-` plus that.
    private static let parameterName = "Region"
    private static let headerName = "Mcp-Param-" + parameterName

    /// A tool whose `region` argument is mirrored into a header.
    private var annotatedTool: Tool {
        Tool(
            name: "deploy",
            description: "Deploys to a region",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "region": .object([
                        "type": .string("string"),
                        "x-mcp-header": .string(Self.parameterName),
                    ])
                ]),
                "required": .array([.string("region")]),
            ]))
    }

    private func startServer(port: UInt16) async throws -> HTTPServerTransport {
        let tool = annotatedTool
        let transport = HTTPServerTransport(port: port, tools: [tool])
        let server = Server(
            name: "custom-header", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [tool], resultType: .complete)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            CallTool.Result(
                content: [.text(
                    text: parameters.arguments?["region"]?.stringValue ?? "", annotations: nil,
                    _meta: nil)],
                isError: false, resultType: .complete)
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        return transport
    }

    /// Call `deploy` with `region` in the body and `headerValue` in the annotated header.
    private func call(
        region: String, headerValue: String?, to port: UInt16
    ) async throws -> (status: Int, json: [String: Any]) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/mcp"
        let url = try #require(components.url)

        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "deploy",
                "arguments": ["region": region],
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": [:],
                ],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
        request.setValue("deploy", forHTTPHeaderField: "Mcp-Name")
        request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
        if let headerValue { request.setValue(headerValue, forHTTPHeaderField: Self.headerName) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    private func base64Sentinel(_ value: String) -> String {
        "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }

    // MARK: - Accepting

    /// Conformance check `ServerAcceptsValidBase64`.
    @Test("A Base64 header matching the body is served")
    func testValidBase64Accepted() async throws {
        let transport = try await startServer(port: 9380)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await call(
            region: "eu-west-1", headerValue: base64Sentinel("eu-west-1"), to: 9380)

        #expect(status == 200)
        #expect(response["error"] == nil)
    }

    /// Conformance checks `ServerLiteralMissingBase64Prefix` and `…Suffix`.
    ///
    /// Only the complete sentinel means "decode this". A value with half of it is a literal —
    /// guessing would mangle any argument that happened to look encoded.
    @Test("A half-sentinel is a literal value, not something to decode", arguments: [
        ("base64?ZXUtd2VzdC0x?=", UInt16(9381)),
        ("=?base64?ZXUtd2VzdC0x", UInt16(9382)),
    ])
    func testHalfSentinelIsLiteral(headerValue: String, port: UInt16) async throws {
        let transport = try await startServer(port: port)
        defer { Task { await transport.disconnect() } }

        // The body holds the same literal, so a server treating it literally sees a match.
        let (status, response) = try await call(
            region: headerValue, headerValue: headerValue, to: port)

        #expect(status == 200)
        #expect(response["error"] == nil, "not a sentinel, so not decoded")
    }

    /// A tool with no annotation is unaffected, and a header nobody declared is ignored.
    @Test("An unannotated argument is not checked against anything")
    func testUnannotatedToolUnaffected() async throws {
        let transport = HTTPServerTransport(port: 9383)
        let server = Server(
            name: "custom-header", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(CallTool.self) { _ in
            CallTool.Result(content: [], isError: false, resultType: .complete)
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await call(
            region: "eu-west-1", headerValue: "something-else", to: 9383)

        #expect(status == 200)
        #expect(response["error"] == nil, "no tool declared this header, so nothing to compare")
    }

    // MARK: - Rejecting

    /// Conformance check `ServerRejectsInvalidBase64Padding`.
    @Test("A sentinel whose Base64 will not decode is refused")
    func testInvalidBase64PaddingRefused() async throws {
        let transport = try await startServer(port: 9384)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await call(
            region: "eu-west-1", headerValue: "=?base64?ZXUtd2VzdC0x=?=", to: 9384)

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }

    /// Conformance check `ServerRejectsInvalidBase64Chars`.
    @Test("A sentinel containing non-Base64 characters is refused")
    func testInvalidBase64CharactersRefused() async throws {
        let transport = try await startServer(port: 9385)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await call(
            region: "eu-west-1", headerValue: "=?base64?not!valid@base64?=", to: 9385)

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }

    /// The core of the rule: the two layers must agree.
    @Test("A header disagreeing with the argument it mirrors is refused")
    func testMismatchRefused() async throws {
        let transport = try await startServer(port: 9386)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await call(
            region: "eu-west-1", headerValue: "us-east-1", to: 9386)

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }

    /// Conformance check `ServerRejectsMissingCustomHeader`: omitting the header while the body
    /// carries the value is the same fault as sending the wrong one — an intermediary that
    /// routes on the header cannot see what the executor will act on.
    @Test("Omitting the header while the body names the value is refused")
    func testMissingHeaderRefused() async throws {
        let transport = try await startServer(port: 9387)
        defer { Task { await transport.disconnect() } }

        let (status, response) = try await call(region: "eu-west-1", headerValue: nil, to: 9387)

        #expect(status == 400)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32020)
    }
}
