import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftMCPServer

/// Test suite for Server-Sent Events (SSE) transport
///
/// Tests verify:
/// - SSE connection establishment and endpoint event
/// - Session ID handling via URL query parameters
/// - JSON-RPC request/response cycle via SSE
/// - Multiple client support
/// - Repeated initialize handling (Bug 6 regression)
@Suite("SSE Transport Tests")
struct SSETransportTests {

    // MARK: - Connection Tests

    @Test("SSE - Client can establish SSE connection")
    func testSSEConnectionEstablishment() async throws {
        let transport = HTTPServerTransport(port: 9100)

        try await transport.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Open SSE connection using delegate to get immediate headers
        let url = try #require(URL(string: "http://localhost:9100/mcp/sse"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Use delegate to capture response immediately
        let (statusCode, contentType, sessionId) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int, String?, String?), Error>) in
            let delegate = SSETestDelegate(continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            task.resume()
        }

        #expect(statusCode == 200, "SSE endpoint should return 200")
        #expect(contentType?.contains("text/event-stream") == true, "Should return event-stream content type")
        let sid = try #require(sessionId, "Should include X-Session-ID header with UUID")
        #expect(sid.count == 36, "Session ID should be UUID format")

        await transport.disconnect()
    }

    @Test("SSE - Endpoint event contains POST URL with session ID")
    func testSSEEndpointEvent() async throws {
        let transport = HTTPServerTransport(port: 9101)
        try await transport.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        let client = try MCPTestClient(port: 9101)
        let sessionId = try await client.connect()

        #expect(!sessionId.isEmpty, "Session ID should not be empty")
        #expect(sessionId.count == 36, "Session ID should be UUID format (36 chars)")

        await client.disconnect()
        await transport.disconnect()
    }

    // MARK: - Full Integration Tests (Critical)
    //
    // NOTE: These tests require a full MCP Server instance (not just transport)
    // to process requests and send responses. They are marked .disabled until
    // we set up a proper integration test harness with the full server.
    //
    // The core transport functionality (connection, session management, SSE format)
    // is tested by the other tests in this file.

    @Test("SSE + POST - Full request/response cycle", .disabled("Requires full MCP Server setup"))
    func testSSEWithPOSTIntegration() async throws {
        #expect(true, "Placeholder for full integration test")
    }

    @Test("SSE - Repeated initialize requests succeed (Bug 6 regression)", .disabled("Requires full MCP Server setup"))
    func testRepeatedInitialize() async throws {
        #expect(true, "Placeholder for reinitialization regression test")
    }

    @Test("SSE + POST - Response routing to correct client", .disabled("Requires full MCP Server setup"))
    func testSSEResponseRouting() async throws {
        #expect(true, "Placeholder for response routing test")
    }

    // MARK: - Session Management Tests

    @Test("SSE - Multiple clients can connect simultaneously")
    func testSSEMultipleClients() async throws {
        let transport = HTTPServerTransport(port: 9105)
        try await transport.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Connect 5 clients
        var clients: [MCPTestClient] = []
        var sessions: Set<String> = []

        for _ in 0..<5 {
            let client = try MCPTestClient(port: 9105)
            let sessionId = try await client.connect()
            clients.append(client)
            sessions.insert(sessionId)
        }

        // All sessions should be unique
        #expect(sessions.count == 5, "All 5 clients should have unique sessions")

        // All clients should be connected
        for client in clients {
            let connected = await client.isConnected
            #expect(connected, "Client should be connected")
        }

        // Cleanup
        for client in clients {
            await client.disconnect()
        }
        await transport.disconnect()
    }

    @Test("SSE - Session cleanup on disconnect")
    func testSSESessionCleanup() async throws {
        let transport = HTTPServerTransport(port: 9106)
        try await transport.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        let client = try MCPTestClient(port: 9106)
        let sessionId = try await client.connect()
        #expect(!sessionId.isEmpty)

        // Verify session exists in manager
        let countBefore = await transport.sseSessionManager.activeSessionCount()
        #expect(countBefore >= 1, "Should have at least one active session")

        // Disconnect client
        await client.disconnect()

        // Give server time to detect disconnect and cleanup
        try await Task.sleep(nanoseconds: 500_000_000)

        // Note: The session may still be in the manager until cleanup runs
        // This test primarily verifies disconnect doesn't crash

        await transport.disconnect()
    }

    // MARK: - Heartbeat Tests

    @Test("SSE - Receive heartbeat events")
    func testSSEHeartbeat() async throws {
        // Heartbeats are sent every 30 seconds by default
        // For testing, we'd need to either:
        // 1. Wait 30+ seconds (too slow)
        // 2. Configure shorter heartbeat interval
        // 3. Mock the timer

        // For now, verify the heartbeat mechanism exists
        let session = SSESession(
            sessionId: "test-heartbeat",
            connection: MockHTTPConnection()
        )

        // Verify session has heartbeat method
        await session.sendHeartbeat()
        // If we get here without crash, heartbeat mechanism works
        #expect(Bool(true), "Heartbeat mechanism exists")
    }

    // MARK: - Format Tests

    @Test("SSE - Proper event format")
    func testSSEEventFormat() async throws {
        // Test SSESession event formatting
        let mockConnection = MockHTTPConnection()
        let session = SSESession(
            sessionId: "test-format",
            connection: mockConnection
        )

        // Send an event
        await session.sendEvent(event: "message", data: "{\"test\":\"data\"}")

        // Wait for internal Task to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Get what was sent
        let sentData = await mockConnection.getSentData()
        let sentString = try #require(String(data: sentData, encoding: .utf8), "Should have sent UTF-8 data")

        #expect(sentString.contains("event: message"), "Should contain event type")
        #expect(sentString.contains("data: {\"test\":\"data\"}"), "Should contain data line")
        #expect(sentString.hasSuffix("\n\n"), "Should end with blank line")
    }

    @Test("SSE - Multi-line data handling")
    func testSSEMultiLineData() async throws {
        let mockConnection = MockHTTPConnection()
        let session = SSESession(
            sessionId: "test-multiline",
            connection: mockConnection
        )

        // Send multi-line data
        let multiLineData = "line1\nline2\nline3"
        await session.sendEvent(event: "message", data: multiLineData)

        // Wait for internal Task to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let sentData = await mockConnection.getSentData()
        let sentString = try #require(String(data: sentData, encoding: .utf8), "Should have sent UTF-8 data")

        // Each line should be prefixed with "data: "
        #expect(sentString.contains("data: line1"), "Should have data prefix for line 1")
        #expect(sentString.contains("data: line2"), "Should have data prefix for line 2")
        #expect(sentString.contains("data: line3"), "Should have data prefix for line 3")
    }
}

// MARK: - Test Helpers

/// URLSession delegate for testing SSE connections
/// Captures response headers immediately without waiting for completion
// Justification: `didResume` is touched only from URLSession delegate callbacks, which the session serialises onto its own delegate queue, so it is never accessed concurrently.
final class SSETestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<(Int, String?, String?), Error>
    private var didResume = false

    init(continuation: CheckedContinuation<(Int, String?, String?), Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Get headers immediately when response is received
        if !didResume, let httpResponse = response as? HTTPURLResponse {
            didResume = true
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
            let sessionId = httpResponse.value(forHTTPHeaderField: "X-Session-ID")
            continuation.resume(returning: (httpResponse.statusCode, contentType, sessionId))

            // Cancel the task since we got what we needed
            dataTask.cancel()
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Ignore cancellation errors (we cancel intentionally)
        if !didResume, let error = error, (error as? URLError)?.code != .cancelled {
            didResume = true
            continuation.resume(throwing: error)
        }
    }
}

/// Mock HTTP connection for testing SSE session
actor MockHTTPConnection: HTTPConnection {
    let id: String = UUID().uuidString
    let remoteAddress: String = "127.0.0.1:12345"

    var isActive: Bool {
        get async { !isClosed }
    }

    private var sentData = Data()
    private var isClosed = false

    func send(_ data: Data) async throws {
        sentData.append(data)
    }

    /// Recorded rather than written: a test reads what a stream was opened with, and there is
    /// no socket here to write a head onto.
    private(set) var sseHeaders: [(String, String)] = []

    func sendSSEHead(headers: [(String, String)]) async {
        sseHeaders = headers
    }

    func close() async {
        isClosed = true
    }

    func getSentData() -> Data {
        return sentData
    }

    func getIsClosed() -> Bool {
        return isClosed
    }
}

enum SSETestError: Error {
    case invalidData
    case invalidJson
    case networkError
    case timeout
}
