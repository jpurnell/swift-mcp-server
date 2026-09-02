import Foundation
#if canImport(os)
import os
#endif

/// Represents a single Server-Sent Events (SSE) client connection
///
/// SSE provides a one-way channel from server to client for:
/// - JSON-RPC responses
/// - Server-initiated notifications
/// - Progress updates
/// - Log messages
///
/// ## SSE Event Format
///
/// ```
/// event: message
/// data: {"jsonrpc":"2.0","id":1,"result":{...}}
///
/// ```
///
/// Multiple `data:` lines are supported for multi-line payloads.
public actor SSESession {
    /// Unique identifier for this session
    public let sessionId: String

    /// The HTTP connection for this SSE stream
    private let connection: HTTPConnection

    /// When this session was created
    public let createdAt: Date

    /// Last time any activity occurred
    private(set) var lastActivityAt: Date

    /// Whether this session is active
    private(set) var isActive: Bool = true

    /// Logger for this session
    private let logger: os.Logger

    /// Initialize a new SSE session
    /// - Parameters:
    ///   - sessionId: Unique identifier (default: UUID)
    ///   - connection: HTTP connection to send events to
    public init(
        sessionId: String = UUID().uuidString,
        connection: HTTPConnection
    ) {
        self.sessionId = sessionId
        self.connection = connection
        self.createdAt = Date()
        self.lastActivityAt = Date()
        self.logger = os.Logger(subsystem: "com.swiftmcp", category: "SSESession")
    }

    /// Send an SSE event to the client
    /// - Parameters:
    ///   - event: Event type (e.g., "message", "error")
    ///   - data: Event payload (will be JSON-encoded if needed)
    ///   - id: Optional event ID for client-side deduplication
    public func sendEvent(event: String = "message", data: String, id: String? = nil) {
        guard isActive else {
            logger.warning("Attempted to send event to inactive session \(self.sessionId, privacy: .public)")
            return
        }

        // Build SSE event format
        var parts: [String] = []

        if let eventId = id {
            parts.append("id: \(eventId)\n")
        }

        parts.append("event: \(event)\n")

        // Handle multi-line data (each line must be prefixed with "data: ")
        //
        // Splits on `isNewline` rather than the "\n" literal. "\r\n" is a single Character
        // in Swift — one extended grapheme cluster — so splitting on "\n" never matches it,
        // and a CRLF-bearing payload comes back as one element. The `data: ` prefixing then
        // silently applies to the whole blob, leaving a bare CR LF inside a data line, which
        // the SSE reader treats as a line terminator. The event arrives truncated with
        // nothing having thrown. `isNewline` also covers CR alone and the Unicode line
        // separators, which the SSE spec accepts as line endings.
        let dataLines = data.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        parts.append(contentsOf: dataLines.map { "data: \($0)\n" })

        // SSE events end with blank line
        parts.append("\n")
        let sseEvent = parts.joined()

        // Send to client
        guard let eventData = sseEvent.data(using: .utf8) else {
            logger.error("Failed to encode SSE event for session \(self.sessionId, privacy: .public)")
            return
        }

        Task {
            await self.sendData(eventData, debugLabel: "SSE event")
        }
    }

    /// Send a heartbeat/keepalive event
    ///
    /// SSE comment format: `: comment\n\n`
    /// This prevents connection timeout without sending data
    public func sendHeartbeat() {
        guard isActive else { return }

        let heartbeat = ":\n\n"
        guard let heartbeatData = heartbeat.data(using: .utf8) else { return }

        Task {
            await self.sendData(heartbeatData, debugLabel: "heartbeat")
        }
    }

    private func sendData(_ data: Data, debugLabel: String) async {
        do {
            try await connection.send(data)
            lastActivityAt = Date()
        } catch {
            logger.error("Failed to send \(debugLabel, privacy: .public) to session \(self.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await close()
        }
    }

    /// Send a JSON-RPC response via SSE
    /// - Parameter jsonRpcResponse: The JSON-RPC response data
    public func sendJSONRPCResponse(_ jsonRpcResponse: Data) {
        guard let jsonString = String(data: jsonRpcResponse, encoding: .utf8) else {
            logger.error("Failed to convert JSON-RPC response to string")
            return
        }

        sendEvent(event: "message", data: jsonString)
    }

    /// Close this SSE session
    public func close() async {
        guard isActive else { return }

        isActive = false
        await connection.close()
        logger.debug("Closed SSE session \(self.sessionId, privacy: .public)")
    }

    /// Check if session has timed out
    /// - Parameter timeout: Maximum idle time before timeout
    /// - Returns: Whether session should be considered timed out
    public func isTimedOut(timeout: TimeInterval) -> Bool {
        return Date().timeIntervalSince(lastActivityAt) > timeout
    }
}
