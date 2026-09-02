import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A reusable test client for MCP SSE integration tests
///
/// `MCPTestClient` provides a complete client implementation for testing
/// MCP over SSE transport, including:
/// - SSE connection establishment
/// - Event parsing and collection
/// - JSON-RPC request sending via POST
/// - Response waiting with timeout
///
/// ## Example
///
/// ```swift
/// let client = MCPTestClient(port: 9100)
/// let sessionId = try await client.connect()
/// let response = try await client.sendRequest("initialize", params: [...])
/// await client.disconnect()
/// ```
actor MCPTestClient {
    /// Base URL for the MCP server
    let baseURL: URL

    /// Port number
    let port: Int

    /// Current session ID from SSE connection
    private(set) var sessionId: String?

    /// POST endpoint URL (from SSE endpoint event)
    private(set) var postEndpoint: String?

    /// Collected SSE events
    private(set) var receivedEvents: [SSEEvent] = []

    /// Whether currently connected
    private(set) var isConnected: Bool = false

    /// The URLSession for HTTP requests
    private var session: URLSession?

    /// The SSE data task
    private var sseTask: URLSessionDataTask?

    /// Event continuation for async event waiting
    private var eventContinuation: CheckedContinuation<SSEEvent, Error>?

    /// SSE delegate for handling streaming data
    private var sseDelegate: MCPSSEDelegate?

    /// Initialize a test client
    /// - Parameter port: The port number the MCP server is listening on
    init(port: Int) throws {
        self.port = port
        // Assembled field by field rather than interpolated into a string. `port` is the
        // only variable, and setting it through URLComponents means it can never widen
        // into a host, a scheme, or a path — which is what makes this not SSRF-shaped.
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = port
        guard let url = components.url else {
            throw MCPTestClientError.invalidURL(components.description)
        }
        self.baseURL = url
    }

    /// Connect to the SSE endpoint
    ///
    /// Establishes an SSE connection and captures the session ID
    /// from the endpoint event.
    ///
    /// - Returns: The session ID
    /// - Throws: If connection fails or times out
    func connect() async throws -> String {
        let url = baseURL.appendingPathComponent("/mcp/sse")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Create delegate to handle SSE stream
        let delegate = MCPSSEDelegate()
        self.sseDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.dataTask(with: request)
        self.sseTask = task
        task.resume()

        // Wait for endpoint event with session ID
        let startTime = Date()
        let timeout: TimeInterval = 5.0

        while Date().timeIntervalSince(startTime) < timeout {
            if let event = delegate.getNextEvent(),
               event.type == "endpoint" {
                // Parse session ID from endpoint URL
                // Format: /mcp?sessionId=XXX
                if let queryStart = event.data.firstIndex(of: "?") {
                    let queryString = String(event.data[event.data.index(after: queryStart)...])
                    let params = queryString.split(separator: "&")
                    for param in params {
                        let parts = param.split(separator: "=", maxSplits: 1)
                        if parts.count == 2 && parts[0] == "sessionId" {
                            let sessionId = String(parts[1])
                            self.sessionId = sessionId
                            self.postEndpoint = event.data
                            self.isConnected = true
                            return sessionId
                        }
                    }
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        throw MCPTestClientError.connectionTimeout
    }

    /// Send a JSON-RPC request via POST
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name
    ///   - params: Optional parameters
    ///   - id: Request ID (default: 1)
    /// - Returns: The JSON response
    /// - Throws: If request fails or response is invalid
    func sendRequest(_ method: String, params: [String: Any]? = nil, id: Int = 1) async throws -> JSONRPCResponse {
        guard let sessionId = sessionId else {
            throw MCPTestClientError.notConnected
        }

        // Build JSON-RPC request
        var jsonRpc: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": id
        ]
        if let params = params {
            jsonRpc["params"] = params
        }

        let requestData = try JSONSerialization.data(withJSONObject: jsonRpc)

        // Build POST URL with session ID
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MCPTestClientError.invalidURL(baseURL.absoluteString)
        }
        components.path = "/mcp"
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]

        guard let postURL = components.url else {
            throw MCPTestClientError.invalidURL(components.description)
        }
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.httpBody = requestData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPTestClientError.invalidResponse
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 202 else {
            throw MCPTestClientError.httpError(statusCode: httpResponse.statusCode)
        }

        // For SSE transport, response comes via SSE stream
        // Wait for SSE event with matching ID
        let event = try await waitForEvent(matching: { event in
            guard event.type == "message" else { return false }
            guard let json = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                return false
            }
            if let responseId = json["id"] as? Int, responseId == id {
                return true
            }
            return false
        }, timeout: 10.0)

        return try JSONRPCResponse.parse(from: event.data)
    }

    /// Wait for an SSE event matching a predicate
    ///
    /// - Parameters:
    ///   - predicate: Function to test each event
    ///   - timeout: Maximum wait time in seconds
    /// - Returns: The matching event
    /// - Throws: If timeout expires
    func waitForEvent(matching predicate: @escaping (SSEEvent) -> Bool, timeout: TimeInterval) async throws -> SSEEvent {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if let event = sseDelegate?.getNextEvent() {
                receivedEvents.append(event)
                if predicate(event) {
                    return event
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        throw MCPTestClientError.timeout
    }

    /// Wait for any SSE event
    ///
    /// - Parameter timeout: Maximum wait time in seconds
    /// - Returns: The next event
    /// - Throws: If timeout expires
    func waitForAnyEvent(timeout: TimeInterval = 5.0) async throws -> SSEEvent {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if let event = sseDelegate?.getNextEvent() {
                receivedEvents.append(event)
                return event
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        throw MCPTestClientError.timeout
    }

    /// Disconnect from the server
    func disconnect() async {
        sseTask?.cancel()
        sseTask = nil
        session?.invalidateAndCancel()
        session = nil
        sseDelegate = nil
        isConnected = false
        sessionId = nil
        postEndpoint = nil
        receivedEvents = []
    }

    /// Get all received events
    func getAllEvents() -> [SSEEvent] {
        return receivedEvents
    }

    /// Clear received events
    func clearEvents() {
        receivedEvents = []
    }
}

// MARK: - Supporting Types

/// Represents a parsed SSE event
struct SSEEvent: Sendable {
    let type: String
    let data: String
    let id: String?

    init(type: String = "message", data: String, id: String? = nil) {
        self.type = type
        self.data = data
        self.id = id
    }
}

/// A Sendable JSON-RPC response for test use
struct JSONRPCResponse: Sendable {
    let jsonrpc: String
    let id: Int?
    let hasResult: Bool
    let hasError: Bool
    let rawJSON: String

    /// Parse from JSON string
    static func parse(from jsonString: String) throws -> JSONRPCResponse {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPTestClientError.invalidJSON
        }

        return JSONRPCResponse(
            jsonrpc: json["jsonrpc"] as? String ?? "2.0",
            id: json["id"] as? Int,
            hasResult: json["result"] != nil,
            hasError: json["error"] != nil,
            rawJSON: jsonString
        )
    }

    /// Check if response has a specific key in result
    func resultContains(key: String) -> Bool {
        guard let data = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return false
        }
        return result[key] != nil
    }
}

/// Errors that can occur in MCPTestClient
enum MCPTestClientError: Error, LocalizedError {
    case notConnected
    case invalidURL(String)
    case connectionTimeout
    case timeout
    case invalidResponse
    case invalidJSON
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to SSE endpoint"
        case .invalidURL(let string):
            return "Could not build a URL from \(string)"
        case .connectionTimeout:
            return "Connection to SSE endpoint timed out"
        case .timeout:
            return "Operation timed out"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .invalidJSON:
            return "Invalid JSON in response"
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}

/// URLSession delegate for handling SSE data streams
// Justification: every read and write of `buffer` and `events` is bracketed by `lock`; verified 2026-08-25 that no access path bypasses it.
final class MCPSSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var buffer = ""
    private var events: [SSEEvent] = []
    private let lock = NSLock()

    /// Get the next available event (removes from queue)
    func getNextEvent() -> SSEEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }

    /// Get all available events (clears queue)
    func getAllEvents() -> [SSEEvent] {
        lock.lock()
        defer { lock.unlock() }
        let result = events
        events = []
        return result
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        ingest(text)
    }

    /// Feed one chunk of SSE stream text through the frame parser.
    ///
    /// Split out from the `URLSession` callback so the parser can be exercised directly with
    /// a chosen line-ending form; fabricating a `URLSessionDataTask` to reach it is not
    /// possible from a test.
    func ingest(_ text: String) {
        lock.lock()
        buffer += text

        // Parse SSE events from buffer. A blank line ends an event, but "blank" depends on
        // the terminator: the SSE grammar allows a line to end with CRLF, a bare LF, or a
        // bare CR, so a frame boundary is any two consecutive newline *Characters*. Not
        // `range(of: "\n\n")` — "\r\n" is a single Character in Swift, so that search
        // matches none of the CRLF or CR forms and frames would never be detected at all,
        // leaving the buffer to grow without bound. Same root cause as the line-splitting
        // defect below, one level up.
        while let eventEnd = Self.frameBoundary(in: buffer) {
            let eventText = String(buffer[..<eventEnd.lowerBound])
            buffer = String(buffer[eventEnd.upperBound...])

            // Parse event fields
            var eventType = "message"
            var eventData = ""
            var eventId: String? = nil

            // Not `split(separator: "\n")`. "\r\n" is a single Character in Swift — one
            // extended grapheme cluster — so that call never matches it and an SSE frame
            // comes back as one element containing every field. Server-Sent Events are
            // CRLF-terminated in practice, so this is the common case, not the exotic one.
            // Same defect that was fixed in SSESession.swift on 2026-08-18.
            for line in eventText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let lineStr = String(line)
                if lineStr.hasPrefix("event:") {
                    eventType = lineStr.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if lineStr.hasPrefix("data:") {
                    let dataLine = lineStr.dropFirst(5).trimmingCharacters(in: .init(charactersIn: " "))
                    if !eventData.isEmpty {
                        eventData += "\n"
                    }
                    eventData += dataLine
                } else if lineStr.hasPrefix("id:") {
                    eventId = lineStr.dropFirst(3).trimmingCharacters(in: .whitespaces)
                }
            }

            if !eventData.isEmpty || eventType != "message" {
                events.append(SSEEvent(type: eventType, data: eventData, id: eventId))
            }
        }
        lock.unlock()
    }

    /// Locate a frame boundary: the range spanning two consecutive newline `Character`s.
    ///
    /// `Character.isNewline` is true for LF, CR and the CRLF pair alike, and Swift collapses
    /// a CR followed by an LF into one `Character` — including across a `+=` that joins two
    /// stream chunks — so scanning by `Character` recognises every terminator form the SSE
    /// grammar permits without ever inventing a boundary at a chunk seam.
    private static func frameBoundary(in s: String) -> Range<String.Index>? {
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(after: i)
            guard j < s.endIndex else { return nil }
            if s[i].isNewline && s[j].isNewline {
                return i..<s.index(after: j)
            }
            i = j
        }
        return nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
    }
}
