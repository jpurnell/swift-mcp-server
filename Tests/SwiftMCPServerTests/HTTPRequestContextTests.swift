import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer
import MCP

/// A handler's access to the HTTP request that triggered it.
///
/// `withMethodHandler` takes decoded parameters and nothing else, which is right for almost
/// everything — a tool should not care how it was reached. But some rules are *about* the
/// transport: SEP-2243's custom `x-mcp-header` parameters must be checked against the headers
/// that carried them, and there is no way to do that from a handler that cannot see them.
///
/// The SDK already defines `HTTPContextProviding` for this; conforming the transport is what
/// connects it.
@Suite("HTTP request context")
struct HTTPRequestContextTests {

    /// Records what a handler could see about its own HTTP request.
    // Justification: a reference box written once by one handler and read after the await
    private final class Observed: @unchecked Sendable {
        var headerValue: String?
        var method: String?
        var path: String?
    }

    private func post(
        _ body: [String: Any], to port: UInt16, headers: [String: String]
    ) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port)
        components.path = "/mcp"
        let url = try #require(components.url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @Test("A handler can read the headers of the request that reached it")
    func testHandlerSeesRequestHeaders() async throws {
        let observed = Observed()
        let transport = HTTPServerTransport(port: 9370)
        let server = Server(
            name: "context", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            let context = Server.currentHandlerContext?.httpContext
            observed.headerValue = context?.header("Mcp-Param-Region")
            observed.method = context?.method
            observed.path = context?.path
            return ListTools.Result(tools: [], resultType: .complete)
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        defer { Task { await transport.disconnect() } }

        _ = try await post(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]], to: 9370,
            headers: ["Mcp-Param-Region": "eu-west-1"])

        #expect(observed.headerValue == "eu-west-1")
        #expect(observed.method == "POST")
        #expect(observed.path == "/mcp")
    }

    /// Header lookup is case-insensitive, because HTTP field names are — a handler that only
    /// matched the casing it happened to expect would work until an intermediary normalised it.
    @Test("Header lookup does not depend on how the client capitalised it")
    func testHeaderLookupIsCaseInsensitive() async throws {
        let observed = Observed()
        let transport = HTTPServerTransport(port: 9371)
        let server = Server(
            name: "context", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            observed.headerValue =
                Server.currentHandlerContext?.httpContext?.header("mcp-param-region")
            return ListTools.Result(tools: [], resultType: .complete)
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        defer { Task { await transport.disconnect() } }

        _ = try await post(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]], to: 9371,
            headers: ["MCP-PARAM-REGION": "us-east-1"])

        #expect(observed.headerValue == "us-east-1")
    }

    /// The context is held only while the request is in flight. Keeping it afterwards would
    /// grow without bound on a long-lived server, and the protocol says a request id is only
    /// meaningful until it is answered.
    @Test("The context is released once the response has been delivered")
    func testContextIsReleasedAfterResponse() async throws {
        let transport = HTTPServerTransport(port: 9372)
        let server = Server(
            name: "context", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [], resultType: .complete)
        }
        try await server.start(transport: transport)
        try await Task.sleep(nanoseconds: 400_000_000)
        defer { Task { await transport.disconnect() } }

        _ = try await post(
            ["jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": [:]], to: 9372,
            headers: [:])
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(await transport.httpRequestContext(for: .number(7)) == nil)
    }
}
