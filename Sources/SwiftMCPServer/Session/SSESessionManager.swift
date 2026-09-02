import Foundation
#if canImport(os)
import os
#endif

/// Manages multiple concurrent SSE sessions
///
/// Responsibilities:
/// - Track active SSE connections
/// - Route responses to correct session
/// - Clean up inactive/timed-out sessions
/// - Broadcast notifications to all clients
public actor SSESessionManager {
    private let logger: os.Logger

    /// Active SSE sessions indexed by session ID
    private var sessions: [String: SSESession] = [:]

    /// Mapping of JSON-RPC request IDs to session IDs
    /// When a request comes in via POST, we need to know which SSE stream to send the response to
    private var requestToSession: [HTTPResponseManager.JSONRPCId: String] = [:]

    /// Session timeout (default: 5 minutes)
    private let sessionTimeout: TimeInterval

    /// Heartbeat interval (default: 30 seconds)
    private let heartbeatInterval: TimeInterval

    /// Cleanup task for expired sessions
    private var cleanupTask: Task<Void, Never>?

    /// Heartbeat task for keepalive
    private var heartbeatTask: Task<Void, Never>?

    /// Initialize the session manager
    /// - Parameters:
    ///   - sessionTimeout: Max idle time before session expires (default: 300s)
    ///   - heartbeatInterval: How often to send keepalive (default: 30s)
    public init(
        sessionTimeout: TimeInterval = 300.0,
        heartbeatInterval: TimeInterval = 30.0
    ) {
        self.sessionTimeout = sessionTimeout
        self.heartbeatInterval = heartbeatInterval
        self.logger = os.Logger(subsystem: "com.swiftmcp", category: "SSESessionManager")
    }

    // MARK: - Session Lifecycle

    /// Register a new SSE session
    /// - Parameter session: The SSE session to register
    public func registerSession(_ session: SSESession) async {
        let sessionId = session.sessionId
        sessions[sessionId] = session
        logger.info("Registered SSE session: \(sessionId, privacy: .public)")
    }

    /// Get a session by ID
    /// - Parameter sessionId: The session identifier
    /// - Returns: The session, if it exists
    public func getSession(_ sessionId: String) -> SSESession? {
        return sessions[sessionId]
    }

    /// Remove a session
    /// - Parameter sessionId: The session to remove
    public func removeSession(_ sessionId: String) {
        if let session = sessions.removeValue(forKey: sessionId) {
            Task {
                await session.close()
            }
            logger.info("Removed SSE session: \(sessionId, privacy: .public)")
        }

        // Clean up any request mappings for this session
        requestToSession = requestToSession.filter { $0.value != sessionId }
    }

    /// Get count of active sessions
    public func activeSessionCount() -> Int {
        return sessions.count
    }

    // MARK: - Request/Response Correlation

    /// Associate a JSON-RPC request with an SSE session
    /// - Parameters:
    ///   - requestId: The JSON-RPC request ID
    ///   - sessionId: The SSE session that should receive the response
    public func associateRequest(requestId: HTTPResponseManager.JSONRPCId, with sessionId: String) {
        requestToSession[requestId] = sessionId
        logger.debug("Associated request \(requestId, privacy: .public) with session \(sessionId, privacy: .public)")
    }

    /// Route a JSON-RPC response to the appropriate SSE session
    /// - Parameter responseData: The JSON-RPC response
    /// - Returns: Whether the response was successfully routed
    public func routeResponse(_ responseData: Data) -> Bool {
        // Extract JSON-RPC ID
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any], // silent: returns false for non-JSON data
              let requestId = extractRequestId(from: json) else {
            logger.warning("Could not extract request ID from response")
            return false
        }

        // Find the session for this request
        guard let sessionId = requestToSession.removeValue(forKey: requestId) else {
            logger.warning("No session found for request \(requestId, privacy: .public)")
            return false
        }

        // Send response via SSE
        guard let session = sessions[sessionId] else {
            logger.warning("Session \(sessionId, privacy: .public) no longer exists")
            return false
        }

        Task {
            await session.sendJSONRPCResponse(responseData)
        }

        logger.debug("Routed response for request \(requestId, privacy: .public) to session \(sessionId, privacy: .public)")
        return true
    }

    /// Extract JSON-RPC ID from parsed JSON
    private func extractRequestId(from json: [String: Any]) -> HTTPResponseManager.JSONRPCId? {
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

    // MARK: - Broadcasting

    /// Broadcast a notification to all active sessions
    /// - Parameters:
    ///   - event: Event type
    ///   - data: Event data
    public func broadcast(event: String = "notification", data: String) {
        logger.debug("Broadcasting \(event, privacy: .public) to \(self.sessions.count, privacy: .public) sessions")

        for session in sessions.values {
            Task {
                await session.sendEvent(event: event, data: data)
            }
        }
    }

    // MARK: - Maintenance Tasks

    /// Start periodic maintenance (cleanup + heartbeat)
    public func startMaintenance() {
        guard cleanupTask == nil && heartbeatTask == nil else { return }

        // Start cleanup task
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // silent: sleep cancellation is expected during shutdown
                await self?.cleanupExpiredSessions()
            }
        }

        // Start heartbeat task
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000)) // silent: sleep cancellation is expected during shutdown
                await self.sendHeartbeats()
            }
        }

        logger.info("Started SSE maintenance tasks")
    }

    /// Stop maintenance tasks
    public func stopMaintenance() {
        cleanupTask?.cancel()
        cleanupTask = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        logger.info("Stopped SSE maintenance tasks")
    }

    /// Remove sessions that have timed out
    private func cleanupExpiredSessions() async {
        var expiredIds: [String] = []
        for (sessionId, session) in sessions {
            if await session.isTimedOut(timeout: sessionTimeout) {
                expiredIds.append(sessionId)
            }
        }
        guard !expiredIds.isEmpty else { return }
        let expiredSet = Set(expiredIds)
        for id in expiredIds {
            if let session = sessions.removeValue(forKey: id) {
                Task { await session.close() }
            }
            logger.info("Cleaned up expired session: \(id, privacy: .public)")
        }
        requestToSession = requestToSession.filter { !expiredSet.contains($0.value) }
    }

    /// Send heartbeat to all active sessions
    private func sendHeartbeats() {
        for session in sessions.values {
            Task {
                await session.sendHeartbeat()
            }
        }
    }

    /// Close all sessions and stop maintenance
    public func shutdown() {
        stopMaintenance()

        for session in sessions.values {
            Task {
                await session.close()
            }
        }

        sessions.removeAll()
        requestToSession.removeAll()

        logger.info("SSE session manager shutdown complete")
    }
}
