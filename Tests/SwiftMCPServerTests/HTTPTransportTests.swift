import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer

/// Test suite for HTTP transport request/response cycle
///
/// Tests follow TDD principles:
/// 1. RED: Write failing tests first
/// 2. GREEN: Make tests pass with minimal code
/// 3. REFACTOR: Improve implementation
@Suite("HTTP Transport Tests")
struct HTTPTransportTests {

    // MARK: - Phase 1: Request/Response Correlation

    /// Route a response whose `id` matches a registered request.
    ///
    /// These four tests previously asserted on `JSONSerialization` round-tripping a literal
    /// string and never constructed an `HTTPResponseManager` — they would have passed with
    /// the type deleted. They now drive the actor through the `HTTPConnection` seam.
    @Test("HTTPResponseManager - Register and route simple request")
    func testResponseManagerBasicFlow() async throws {
        let manager = HTTPResponseManager()
        let connection = MockHTTPConnection()

        await manager.registerRequest(requestId: .number(42), connection: connection)
        #expect(await manager.pendingCount() == 1, "registering should leave one request pending")

        let responseData = try #require(#"{"jsonrpc":"2.0","id":42,"result":{"tools":[]}}"#.data(using: .utf8))
        let routed = await manager.routeResponse(responseData)

        #expect(routed, "a response whose id matches a pending request should route")
        #expect(await manager.pendingCount() == 0, "routing should consume the pending request")

        // `routeResponse` returns before the bytes are written: the send is dispatched into a
        // detached `Task`, so a `true` return means "matched and handed off", not "delivered".
        // A failed send is only logged and never reaches the caller. Poll for the write.
        let text = try #require(await Self.awaitSentText(from: connection),
                                "the connection received nothing within the deadline")
        #expect(text.contains("200"), "the connection should have received a 200 response")
        #expect(text.contains("\"tools\""), "the response body should reach the connection")
    }

    /// Wait briefly for the detached send task to write to `connection`.
    private static func awaitSentText(
        from connection: MockHTTPConnection,
        timeout: TimeInterval = 2.0
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let sent = await connection.getSentData()
            if !sent.isEmpty {
                return String(data: sent, encoding: .utf8)
            }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        return nil
    }

    @Test("HTTPResponseManager - Handle string request IDs")
    func testResponseManagerStringIds() async throws {
        let manager = HTTPResponseManager()
        let connection = MockHTTPConnection()

        await manager.registerRequest(requestId: .string("request-123"), connection: connection)

        let responseData = try #require(#"{"jsonrpc":"2.0","id":"request-123","result":{"success":true}}"#.data(using: .utf8))
        #expect(await manager.routeResponse(responseData), "a string id should route")
        #expect(await manager.pendingCount() == 0)
    }

    @Test("HTTPResponseManager - Handle null request IDs")
    func testResponseManagerNullIds() async throws {
        let manager = HTTPResponseManager()
        let connection = MockHTTPConnection()

        await manager.registerRequest(requestId: .null, connection: connection)

        let responseData = try #require(#"{"jsonrpc":"2.0","id":null,"result":{}}"#.data(using: .utf8))
        #expect(await manager.routeResponse(responseData), "an explicit null id should route")
        #expect(await manager.pendingCount() == 0)
    }

    /// A response that matches nothing pending must be refused rather than silently dropped.
    @Test("HTTPResponseManager - Unmatched and unparsable responses do not route")
    func testResponseManagerRejectsUnroutable() async throws {
        let manager = HTTPResponseManager()

        let unmatched = try #require(#"{"jsonrpc":"2.0","id":99,"result":{}}"#.data(using: .utf8))
        #expect(await manager.routeResponse(unmatched) == false, "no pending request means no route")

        let notJson = try #require("this is not json".data(using: .utf8))
        #expect(await manager.routeResponse(notJson) == false, "an unparsable body should not route")

        #expect(await manager.pendingCount() == 0)
    }

    /// Distinct id *cases* are distinct keys: `.number(1)` and `.string("1")` are not the same
    /// pending request, so a response carrying one must not consume the other.
    @Test("HTTPResponseManager - A numeric id does not match a string id")
    func testNumericAndStringIdsAreDistinct() async throws {
        let manager = HTTPResponseManager()

        await manager.registerRequest(requestId: .string("1"), connection: MockHTTPConnection())

        let numericResponse = try #require(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.data(using: .utf8))
        #expect(await manager.routeResponse(numericResponse) == false,
                "id 1 must not satisfy the pending \"1\"")
        #expect(await manager.pendingCount() == 1, "the string-keyed request should still be pending")
    }

    @Test("HTTPResponseManager - Cleanup starts and stops without consuming live requests")
    func testResponseManagerCleanup() async throws {
        let manager = HTTPResponseManager(requestTimeout: 1.0)
        await manager.registerRequest(requestId: .number(7), connection: MockHTTPConnection())

        await manager.startCleanup()
        await manager.startCleanup()   // guarded: a second call must not start a second task
        try await Task.sleep(nanoseconds: 100_000_000)
        await manager.stopCleanup()
        await manager.stopCleanup()    // must be safe to call when nothing is running

        // The cleanup task waits 10s before its first sweep, so a request registered here is
        // still pending regardless of `requestTimeout`. Asserting that is the honest claim;
        // the previous version of this test asserted `#expect(true)`.
        #expect(await manager.pendingCount() == 1,
                "cleanup has not swept yet, so the request should survive")
    }

    @Test("HTTPResponseManager - Pending request count")
    func testPendingRequestCount() async throws {
        let manager = HTTPResponseManager()
        #expect(await manager.pendingCount() == 0, "Should start with zero pending requests")

        await manager.registerRequest(requestId: .number(1), connection: MockHTTPConnection())
        await manager.registerRequest(requestId: .number(2), connection: MockHTTPConnection())
        #expect(await manager.pendingCount() == 2, "each registration should be counted")

        await manager.registerRequest(requestId: .number(1), connection: MockHTTPConnection())
        #expect(await manager.pendingCount() == 2, "re-registering an id should replace, not add")
    }

    // MARK: - Integration Tests

    @Test("HTTP Server - Start and stop")
    func testServerStartStop() async throws {
        let transport = HTTPServerTransport(port: 9090)

        try await transport.connect()

        // Server should be listening
        // Give it a moment to start
        try await Task.sleep(nanoseconds: 100_000_000)

        await transport.disconnect()

        #expect(true, "Server should start and stop without errors")
    }

    @Test("HTTP Server - Health check endpoint")
    func testHealthCheckEndpoint() async throws {
        let transport = HTTPServerTransport(port: 9091)

        try await transport.connect()
        try await Task.sleep(nanoseconds: 200_000_000) // Wait for server to be ready

        // Test health endpoint
        let url = try #require(URL(string: "http://localhost:9091/health"))
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = response as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 200, "Health check should return 200")

        let body = String(data: data, encoding: .utf8)
        #expect(body == "OK", "Health check should return OK")

        await transport.disconnect()
    }

    @Test("HTTP Server - Server info endpoint")
    func testServerInfoEndpoint() async throws {
        let transport = HTTPServerTransport(port: 9092)

        try await transport.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        let url = try #require(URL(string: "http://localhost:9092/mcp"))
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = response as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 200, "Server info should return 200")

        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("MCP Server"), "Should return server info")

        await transport.disconnect()
    }

    // MARK: - Error Cases

    @Test("HTTP Server - 404 for unknown paths")
    func test404ForUnknownPaths() async throws {
        let transport = HTTPServerTransport(port: 9093)

        try await transport.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        let url = try #require(URL(string: "http://localhost:9093/unknown"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (_, response) = try await URLSession.shared.data(for: request)

        let httpResponse = response as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 404, "Unknown paths should return 404")

        await transport.disconnect()
    }

    @Test("HTTP Server - 405 for wrong methods")
    func test405ForWrongMethods() async throws {
        let transport = HTTPServerTransport(port: 9094)

        try await transport.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Try PUT on /mcp (only GET, POST, DELETE allowed)
        let url = try #require(URL(string: "http://localhost:9094/mcp"))
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        let (_, response) = try await URLSession.shared.data(for: request)

        let httpResponse = response as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 405, "Wrong method should return 405")

        await transport.disconnect()
    }
}

enum TestError: Error {
    case invalidData
    case invalidJson
    case networkError
}
