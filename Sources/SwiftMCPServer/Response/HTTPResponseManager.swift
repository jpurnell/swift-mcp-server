import Foundation
import MCP
#if canImport(os)
import os
#endif

/// Manages correlation between JSON-RPC requests and HTTP connections
///
/// The MCP transport protocol is designed for streaming (stdio, WebSocket), but HTTP
/// is request/response based. This manager bridges the gap by:
/// - Tracking which HTTP connection made which JSON-RPC request
/// - Routing MCP server responses back to the correct HTTP connection
/// - Handling timeouts and connection cleanup
///
/// ## Architecture
///
/// ```
/// HTTP POST /mcp -> handleRequest(connection, jsonRpcId)
///                      | Store (jsonRpcId -> connection)
///                      | Forward to MCP server
/// MCP Server processes request
///                      | Calls transport.send(response)
/// send() extracts jsonRpcId from response
///                      | Lookup connection from registry
///                      | Send HTTP response to client
/// ```
public actor HTTPResponseManager {
    private let logger: os.Logger

    /// Registry of pending requests: JSON-RPC ID -> HTTP connection
    private var pendingRequests: [JSONRPCId: PendingRequest] = [:]

    /// Timeout for pending requests (default: 5 minutes)
    private let requestTimeout: TimeInterval

    /// Cleanup task for expired requests
    private var cleanupTask: Task<Void, Never>?

    /// A pending HTTP request awaiting its JSON-RPC response
    private struct PendingRequest {
        let connection: HTTPConnection
        let receivedAt: Date
        let requestId: JSONRPCId
        var mcpSessionId: String?
        /// Whether this request's response has been turned into an SSE stream.
        ///
        /// It is, as soon as the server needs to ask the client something mid-request: the
        /// question has to reach the client before the answer to *this* request exists, and a
        /// single JSON body cannot carry both.
        var isStreaming: Bool = false
        /// The HTTP request that carried this JSON-RPC request.
        ///
        /// Held only while the request is in flight, and dropped with the rest of the entry
        /// once the response is routed: a request id means nothing after it is answered, and
        /// keeping the headers would grow without bound on a long-lived server.
        var httpRequest: MCP.HTTPRequest?
    }

    /// JSON-RPC request/response ID (can be string, number, or null)
    public enum JSONRPCId: Hashable, Codable, Sendable, CustomStringConvertible {
        case string(String)
        case number(Int)
        case null

        /// Human-readable description for logging
        public var description: String {
            switch self {
            case .string(let value): return "string(\(value))"
            case .number(let value): return "number(\(value))"
            case .null: return "null"
            }
        }

        /// Decodes a JSON-RPC ID from the given decoder
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { // silent: trying alternative types
                self = .string(string)
            } else if let number = try? container.decode(Int.self) { // silent: trying alternative types
                self = .number(number)
            } else if container.decodeNil() {
                self = .null
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Invalid JSON-RPC ID type"
                    )
                )
            }
        }

        /// Encodes this JSON-RPC ID to the given encoder
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value):
                try container.encode(value)
            case .number(let value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }
    }

    /// Initialize the response manager
    /// - Parameters:
    ///   - requestTimeout: Maximum time to wait for a response (default: 300s)
    public init(requestTimeout: TimeInterval = 300.0) {
        self.requestTimeout = requestTimeout
        self.logger = os.Logger(subsystem: "com.swiftmcp", category: "HTTPResponseManager")
    }

    /// Start the periodic cleanup task for expired requests
    public func startCleanup() {
        guard cleanupTask == nil else { return }

        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // silent: sleep cancellation is expected during shutdown
                await self?.cleanupExpiredRequests()
            }
        }
    }

    /// Stop the cleanup task
    public func stopCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    deinit {
        cleanupTask?.cancel()
    }

    /// Register a pending request awaiting response
    /// - Parameters:
    ///   - requestId: The JSON-RPC request ID
    ///   - connection: The HTTP connection to send the response to
    ///   - httpRequest: The HTTP request that carried it, so a handler can observe the headers
    ///     the rules it implements are about.
    public func registerRequest(
        requestId: JSONRPCId, connection: HTTPConnection, httpRequest: MCP.HTTPRequest? = nil
    ) {
        let pending = PendingRequest(
            connection: connection,
            receivedAt: Date(),
            requestId: requestId,
            httpRequest: httpRequest
        )
        pendingRequests[requestId] = pending
        logger.debug("Registered pending request: \(requestId, privacy: .public)")
    }

    /// The HTTP request that carried a JSON-RPC request, while it is still in flight.
    ///
    /// - Parameter requestId: The JSON-RPC id.
    /// - Returns: The originating HTTP request, or `nil` once the response has been delivered.
    public func httpRequest(for requestId: JSONRPCId) -> MCP.HTTPRequest? {
        pendingRequests[requestId]?.httpRequest
    }

    /// Attach an Mcp-Session-Id to a pending request so it's included in the response header
    public func setSessionIdForRequest(_ requestId: JSONRPCId, sessionId: String) {
        pendingRequests[requestId]?.mcpSessionId = sessionId
    }

    /// Turns a pending request's response into an SSE stream, if it is not one already.
    ///
    /// **Legacy: this is the pre-`2026-07-28` channel.** That revision removed server-initiated
    /// requests entirely — a server that needs something from the client answers
    /// `resultType: "input_required"` and the client retries (SEP-2322). It exists because this
    /// package still serves earlier revisions, where a tool asking the client to sample or
    /// elicit is the only mechanism there is.
    ///
    /// Internal rather than `public`, and deliberately not `@available(deprecated)`: a consumer
    /// never calls this. It reaches the feature by calling `Server.requestSampling` or
    /// `requestElicitation` from a tool, and the transport decides whether the response has to
    /// become a stream. Deprecating it would warn only at this package's own call site, which
    /// tells nobody anything.
    ///
    /// - Parameter requestId: The request whose response becomes a stream.
    /// - Returns: `false` if there is no such pending request.
    @discardableResult
    internal func beginStreaming(for requestId: JSONRPCId) async -> Bool {
        guard var pending = pendingRequests[requestId] else { return false }
        guard !pending.isStreaming else { return true }

        pending.isStreaming = true
        pendingRequests[requestId] = pending

        var headers: [(String, String)] = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
            // Without this a reverse proxy may accumulate events and release them in batches,
            // which turns a stream into a series of stalls.
            ("X-Accel-Buffering", "no"),
            ("Access-Control-Allow-Origin", "*"),
        ]
        if let sessionId = pending.mcpSessionId {
            headers.append(("Mcp-Session-Id", sessionId))
        }
        await pending.connection.sendSSEHead(headers: headers)
        return true
    }

    /// Writes one message onto a streaming response.
    ///
    /// - Parameters:
    ///   - requestId: The request whose stream to write on.
    ///   - message: The JSON-RPC message to frame as an SSE event.
    /// - Returns: `false` if that request is not streaming.
    @discardableResult
    internal func sendEvent(for requestId: JSONRPCId, message: Data) async -> Bool {
        guard let pending = pendingRequests[requestId], pending.isStreaming else { return false }
        guard let text = String(data: message, encoding: .utf8) else { return false }

        let event = "event: message\ndata: \(text)\n\n"
        try? await pending.connection.send(Data(event.utf8)) // silent: a closed stream is logged by the connection and cannot be recovered here
        return true
    }

    /// Route a JSON-RPC response back to its HTTP connection
    /// - Parameter responseData: The JSON-RPC response (as Data)
    /// - Returns: Whether the response was successfully routed
    public func routeResponse(_ responseData: Data) -> Bool {
        // Extract the JSON-RPC ID from the response
        guard let requestId = extractRequestId(from: responseData) else {
            logger.warning("Could not extract JSON-RPC ID from response")
            return false
        }

        // Look up the pending request
        guard let pending = pendingRequests.removeValue(forKey: requestId) else {
            logger.warning("No pending request found for JSON-RPC ID: \(requestId, privacy: .public)")
            return false
        }

        if pending.isStreaming {
            // The head went out when streaming began, so the result is the stream's last event
            // rather than a body. Its HTTP status was decided then and cannot be revised now,
            // which is one reason a request only starts streaming when it has to.
            let connection = pending.connection
            Task {
                if let text = String(data: responseData, encoding: .utf8) {
                    try? await connection.send(Data("event: message\ndata: \(text)\n\n".utf8)) // silent: a closed stream cannot be recovered here
                }
                await connection.close()
            }
            logger.debug("Closed streaming response for request: \(requestId, privacy: .public)")
            return true
        }

        // Send HTTP response
        sendHTTPResponse(
            connection: pending.connection,
            statusCode: Self.httpStatus(for: responseData),
            body: responseData,
            contentType: "application/json",
            mcpSessionId: pending.mcpSessionId
        )

        logger.debug("Routed response for request: \(requestId, privacy: .public)")
        return true
    }

    /// The HTTP status a JSON-RPC payload should be delivered with.
    ///
    /// MCP 2026-07-28 requires an unimplemented method to answer `404` carrying `-32601`. That
    /// pairing is load-bearing during a client's backward-compatibility probe: a bare `404`
    /// means "not an MCP endpoint, fall back to the legacy transport", while a `404` carrying a
    /// JSON-RPC error means "an MCP endpoint that does not have this method". Answering `200`
    /// would make a modern server indistinguishable from one that simply succeeded.
    ///
    /// The three codes SEP-2575 reserved for the protocol itself answer `400`, because each one
    /// says the request was malformed at the transport boundary: its routing headers disagreed
    /// with its body, it needed a client capability the client never declared, or it named a
    /// revision this server does not speak. A handler that raises one of these is reporting the
    /// same fault the transport's own gate reports, and must not be delivered with a different
    /// status depending on which layer noticed.
    ///
    /// Everything else — including tool execution errors, which are results rather than protocol
    /// failures — stays `200`.
    static func httpStatus(for responseData: Data) -> Int {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any], // silent: a body that will not parse is delivered as-is with 200
            let error = json["error"] as? [String: Any],
            let code = error["code"] as? Int
        else { return 200 }

        switch code {
        case -32601: return 404
        case -32020, -32021, -32022: return 400
        default: return 200
        }
    }

    /// Extract JSON-RPC ID from response data
    private func extractRequestId(from data: Data) -> JSONRPCId? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // silent: returns nil for non-JSON data
            return nil
        }

        // JSON-RPC response has either "id" field or is a notification (no id)
        guard let idValue = json["id"] else {
            return .null
        }

        if let stringId = idValue as? String {
            return .string(stringId)
        } else if let numberId = idValue as? Int {
            return .number(numberId)
        } else if idValue is NSNull {
            return .null
        }

        return nil
    }

    /// Send an HTTP response to a connection using proper HTTP framing
    private func sendHTTPResponse(
        connection: HTTPConnection,
        statusCode: Int,
        body: Data,
        contentType: String,
        mcpSessionId: String? = nil
    ) {
        let localLogger = logger
        Task {
            // Build headers list
            var headers: [(String, String)] = [
                ("Content-Type", contentType),
                ("Content-Length", "\(body.count)"),
                ("Connection", "close")
            ]
            if let sessionId = mcpSessionId {
                headers.append(("Mcp-Session-Id", sessionId))
            }
            // CORS headers for cross-origin requests
            headers.append(("Access-Control-Allow-Origin", "*"))
            headers.append(("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"))
            headers.append(("Access-Control-Allow-Headers", "Content-Type, Authorization, Mcp-Session-Id"))
            headers.append(("Access-Control-Expose-Headers", "Mcp-Session-Id"))

            // Send proper HTTP response (.head, .body, .end)
            do {
                try await connection.sendHTTPResponse(statusCode: statusCode, headers: headers, body: body)
                await connection.close()
            } catch {
                localLogger.error("Failed to send HTTP response: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Clean up requests that have timed out
    private func cleanupExpiredRequests() {
        let now = Date()
        let expired = pendingRequests.filter { _, pending in
            now.timeIntervalSince(pending.receivedAt) > requestTimeout
        }

        for (requestId, pending) in expired {
            pendingRequests.removeValue(forKey: requestId)

            // Send timeout error response
            let errorResponse = """
            {
              "jsonrpc": "2.0",
              "id": \(formatJsonRpcId(requestId)),
              "error": {
                "code": -32603,
                "message": "Request timeout",
                "data": "No response received within \(requestTimeout) seconds"
              }
            }
            """

            if let errorData = errorResponse.data(using: .utf8) {
                sendHTTPResponse(
                    connection: pending.connection,
                    statusCode: 504, // Gateway Timeout
                    body: errorData,
                    contentType: "application/json",
                    mcpSessionId: pending.mcpSessionId
                )
            }

            logger.warning("Request timed out: \(requestId, privacy: .public)")
        }
    }

    /// Format JSON-RPC ID for inclusion in JSON string
    private func formatJsonRpcId(_ id: JSONRPCId) -> String {
        switch id {
        case .string(let value):
            return "\"\(value)\""
        case .number(let value):
            return "\(value)"
        case .null:
            return "null"
        }
    }

    /// Get count of pending requests (for monitoring)
    public func pendingCount() -> Int {
        return pendingRequests.count
    }
}
